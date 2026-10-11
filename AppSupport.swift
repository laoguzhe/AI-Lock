import AppKit
import Carbon
import Darwin

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
            guard pressedAt == nil else { return false }
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
