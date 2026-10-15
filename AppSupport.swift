import AppKit
import Carbon
import Darwin

/// Resolve application artwork before asking Finder for a generic executable icon.
enum ApplicationArtwork {
    private static let cache = NSCache<NSString, NSImage>()

    static func applicationURL(for path: String) -> URL? {
        guard path.hasPrefix("/") else { return nil }
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.path != "/" {
            if url.pathExtension.lowercased() == "app", FileManager.default.fileExists(atPath: url.path) { return url }
            url.deleteLastPathComponent()
        }
        return nil
    }

    private static func image(at url: URL) -> NSImage {
        let key = url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    static func process(pid: pid_t, path: String) -> NSImage? {
        if let url = applicationURL(for: path) { return image(at: url) }
        if let app = NSRunningApplication(processIdentifier: pid), let icon = app.icon { return icon }
        var ancestor = pid
        var visited = Set<pid_t>()
        for _ in 0..<16 {
            guard ancestor > 1, visited.insert(ancestor).inserted else { break }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(ancestor, PROC_PIDTBSDINFO, 0, &info, size) == size else { break }
            ancestor = pid_t(info.pbi_ppid)
            guard ancestor > 1 else { break }
            if let app = NSRunningApplication(processIdentifier: ancestor), let icon = app.icon { return icon }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            if proc_pidpath(ancestor, &buffer, UInt32(buffer.count)) > 0,
               let url = applicationURL(for: String(cString: buffer)) { return image(at: url) }
        }
        return nil
    }

    static func startup(program: String, label: String) -> NSImage? {
        if let url = applicationURL(for: program) { return image(at: url) }
        // Launch labels often append a helper or service suffix to the app bundle ID.
        var identifier = label
        while identifier.contains(".") {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) { return image(at: url) }
            identifier = identifier.split(separator: ".").dropLast().joined(separator: ".")
        }
        return nil
    }
}

enum ApplicationLocations {
    static var searchableRoots: [URL] {
        let manager = FileManager.default
        return unique(manager.urls(for: .applicationDirectory, in: .userDomainMask)
            + manager.urls(for: .applicationDirectory, in: .localDomainMask)
            + manager.urls(for: .applicationDirectory, in: .systemDomainMask))
    }

    static var removableRoots: [URL] {
        let manager = FileManager.default
        return unique(manager.urls(for: .applicationDirectory, in: .userDomainMask)
            + manager.urls(for: .applicationDirectory, in: .localDomainMask))
    }

    static func contains(_ url: URL, in root: URL) -> Bool {
        let path = canonicalURL(url).path
        let base = canonicalURL(root).path
        return path.hasPrefix(base + "/")
    }

    static func canonicalURL(_ url: URL) -> URL {
        // Foundation does not resolve parent symlinks when the final leaf is missing.
        var existing = url.standardizedFileURL
        var missing: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            missing.append(existing.lastPathComponent)
            existing.deleteLastPathComponent()
        }
        var result = existing.resolvingSymlinksInPath().standardizedFileURL
        for component in missing.reversed() { result.appendPathComponent(component) }
        return result.standardizedFileURL
    }

    private static func unique(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }
}

enum HotkeyConfiguration {
    static let quickActionID: UInt32 = 10
    static let searchID: UInt32 = 11
    static func numberKeyCode(_ number: Int) -> UInt32? {
        let codes = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                     kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
        guard (1...9).contains(number) else { return nil }
        return UInt32(codes[number - 1])
    }
}

enum CommandError: LocalizedError {
    case timedOut, failed(Int32), invalidOutput
    var errorDescription: String? {
        switch self {
        case .timedOut: return "采样命令超时"
        case .failed(let status): return "采样命令退出码：\(status)"
        case .invalidOutput: return "无法解析采样命令输出"
        }
    }
}

/// Synchronous utility for background queues only. stderr cannot fill an unread pipe.
enum CommandRunner {
    private final class Output {
        var data = Data()
    }

    static func run(_ executable: String, arguments: [String], timeout: TimeInterval = 4,
                    allowEmptyExit: Bool = false) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let output = Output()
        let read = DispatchGroup()
        read.enter()
        DispatchQueue.global(qos: .utility).async {
            output.data = pipe.fileHandleForReading.readDataToEndOfFile()
            read.leave()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            _ = read.wait(timeout: .now() + 1)
            throw CommandError.timedOut
        }
        guard read.wait(timeout: .now() + 1) == .success else { throw CommandError.timedOut }
        guard process.terminationStatus == 0 || (allowEmptyExit && process.terminationStatus == 1 && output.data.isEmpty) else {
            throw CommandError.failed(process.terminationStatus)
        }
        guard let text = String(data: output.data, encoding: .utf8) else { throw CommandError.invalidOutput }
        return text
    }
}

/// Two short, standalone Command presses; shortcuts and other modifiers cancel the gesture.
struct CommandDoubleTapDetector {
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    mutating func reset() { pressedAt = nil; releasedAt = nil }
    mutating func update(commandDown: Bool, otherKey: Bool, timestamp: TimeInterval) -> Bool {
        if otherKey { reset(); return false }
        if commandDown {
            if let press = pressedAt {
                // A missed Command-up event must not leave the detector stuck forever.
                // A later down event after the maximum tap duration starts a fresh gesture.
                guard timestamp - press > 0.5 else { return false }
                pressedAt = timestamp
                releasedAt = nil
                return false
            }
            pressedAt = timestamp
            return false
        }
        guard let press = pressedAt else { return false }
        pressedAt = nil
        guard timestamp - press <= 0.5 else { releasedAt = nil; return false }
        if let release = releasedAt, press - release <= 0.45 {
            releasedAt = nil
            return true
        }
        releasedAt = timestamp
        return false
    }
}
