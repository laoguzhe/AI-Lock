import AppKit
import Foundation

struct InstalledApplication: Identifiable {
    let url: URL
    let name: String
    let bundleID: String
    let size: Int64
    var id: String { url.path }
}

struct UninstallItem: Identifiable {
    let url: URL
    let size: Int64
    var id: String { url.path }
}

struct AnalyzedFile: Identifiable {
    let url: URL
    let size: Int64
    var id: String { url.path }
}

struct StartupItem: Identifiable {
    let url: URL
    let label: String
    let program: String
    let kind: String
    let enabledAtLogin: Bool
    var id: String { url.path }
}

struct StorageCategory: Identifiable {
    let name: String
    let size: Int64
    let count: Int
    var id: String { name }
}

enum ApplicationUninstaller {
    static func scan() -> [InstalledApplication] {
        let manager = FileManager.default
        let roots = manager.urls(for: .applicationDirectory, in: .userDomainMask) + manager.urls(for: .applicationDirectory, in: .systemDomainMask)
        var applications: [InstalledApplication] = []
        var visited = Set<String>()
        for root in roots {
            guard let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for url in urls where url.pathExtension == "app" && visited.insert(url.standardizedFileURL.path).inserted {
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else { continue }
                let bundle = Bundle(url: url)
                applications.append(InstalledApplication(url: url, name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent, bundleID: bundle?.bundleIdentifier ?? "", size: diskSize(url)))
            }
        }
        return applications.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func relatedItems(for app: InstalledApplication) -> [UninstallItem] {
        guard !app.bundleID.isEmpty else { return [] }
        let manager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let containers = home.appendingPathComponent("Library/Containers", isDirectory: true)
        let groupContainers = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true).appendingPathComponent(app.bundleID, isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true).appendingPathComponent(app.bundleID, isDirectory: true)
        let preferences = home.appendingPathComponent("Library/Preferences", isDirectory: true).appendingPathComponent("\(app.bundleID).plist")
        var candidates: [URL] = [support, caches, preferences]
        for root in [containers, groupContainers] {
            if let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                candidates += urls.filter { $0.lastPathComponent == app.bundleID || $0.lastPathComponent.hasPrefix(app.bundleID + ".") }
            }
        }
        return candidates.compactMap { url in
            guard isInside(url, root: home), manager.fileExists(atPath: url.path), let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
            return UninstallItem(url: url, size: diskSize(url))
        }
    }

    static func uninstall(_ app: InstalledApplication, relatedItems: [UninstallItem]) -> Bool {
        let manager = FileManager.default
        let appPath = app.url.standardizedFileURL.path
        let allowedRoots = manager.urls(for: .applicationDirectory, in: .userDomainMask) + manager.urls(for: .applicationDirectory, in: .systemDomainMask)
        guard allowedRoots.contains(where: { isInside(app.url, root: $0) }), appPath.hasSuffix(".app") else { return false }
        var success = true
        for item in relatedItems.sorted(by: { $0.url.path.count > $1.url.path.count }) {
            guard isInside(item.url, root: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) else { success = false; continue }
            do { try manager.trashItem(at: item.url, resultingItemURL: nil) } catch { success = false }
        }
        do { try manager.trashItem(at: app.url, resultingItemURL: nil) } catch { success = false }
        return success
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = root.standardizedFileURL.path
        return path == base || path.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    private static func diskSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let item as URL in enumerator {
            guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true else { continue }
            if values.isRegularFile == true { total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        }
        return total
    }
}

enum FileAnalyzer {
    static func largeFiles(in root: URL, threshold: Int64 = 100 * 1_024 * 1_024) -> [AnalyzedFile] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var results: [AnalyzedFile] = []
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isSymbolicLink != true, values.isRegularFile == true else { continue }
            let size = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            if size >= threshold { results.append(AnalyzedFile(url: url, size: size)) }
        }
        return results.sorted { $0.size > $1.size }
    }

    static func categories(in root: URL, threshold: Int64 = 100 * 1_024 * 1_024) -> [StorageCategory] {
        let files = largeFiles(in: root, threshold: 1)
        let groups = Dictionary(grouping: files) { file -> String in
            let ext = file.url.pathExtension.lowercased()
            if ["dmg", "pkg", "zip", "7z", "rar"].contains(ext) { return "安装包与压缩文件" }
            if ["mov", "mp4", "mkv", "avi"].contains(ext) { return "视频" }
            if ["jpg", "jpeg", "png", "heic", "tif", "raw"].contains(ext) { return "图片" }
            if ["aif", "aiff", "wav", "mp3", "m4a", "flac"].contains(ext) { return "音频" }
            if ["pdf", "doc", "docx", "ppt", "pptx", "xls", "xlsx"].contains(ext) { return "文档" }
            return "其他大文件"
        }
        return groups.map { name, items in StorageCategory(name: name, size: items.reduce(Int64(0)) { $0 + $1.size }, count: items.count) }
            .sorted { $0.size > $1.size }
    }
}

enum StartupItemInspector {
    static func scan() -> [StartupItem] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let roots: [(URL, String)] = [
            (home.appendingPathComponent("Library/LaunchAgents"), "当前用户 LaunchAgent"),
            (URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true), "系统 LaunchAgent"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true), "系统 LaunchDaemon")
        ]
        var result: [StartupItem] = []
        for (root, kind) in roots {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "plist" {
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let data = try? Data(contentsOf: file), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                let args = plist["ProgramArguments"] as? [String] ?? []
                let program = plist["Program"] as? String ?? args.first ?? "（未声明程序路径）"
                result.append(StartupItem(url: file, label: plist["Label"] as? String ?? file.deletingPathExtension().lastPathComponent,
                                          program: program, kind: kind, enabledAtLogin: (plist["RunAtLoad"] as? Bool ?? false) || (plist["KeepAlive"] != nil)))
            }
        }
        let loginItems = home.appendingPathComponent("Library/Application Support/com.apple.backgroundtaskmanagementagent/backgrounditems.btm")
        if FileManager.default.fileExists(atPath: loginItems.path) {
            result.append(StartupItem(url: loginItems, label: "macOS 后台项目数据库", program: "由系统管理，当前仅标记存在，不解析数据库内容", kind: "登录项数据库", enabledAtLogin: true))
        }
        return result.sorted { $0.kind == $1.kind ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.kind < $1.kind }
    }
}
