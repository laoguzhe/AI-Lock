import AppKit
import Foundation
import Metal

struct InstalledApplication: Identifiable {
    let url: URL
    let name: String
    let bundleID: String
    let size: Int64
    var sizeIsCalculated: Bool = true
    var id: String { url.path }
}

enum ExtensionUninstallCategory: String, CaseIterable, Identifiable {
    case installers
    case browserExtensions
    case screenSavers
    case preferencePanes
    case internetPlugins
    case widgets

    var id: String { rawValue }
    var title: String {
        switch self {
        case .installers: "安装文件"
        case .browserExtensions: "网页浏览器扩展"
        case .screenSavers: "屏幕保护程序"
        case .preferencePanes: "设置面板"
        case .internetPlugins: "Internet 插件"
        case .widgets: "小组件"
        }
    }
    var symbol: String {
        switch self {
        case .installers: "shippingbox.fill"
        case .browserExtensions: "puzzlepiece.extension.fill"
        case .screenSavers: "display"
        case .preferencePanes: "gearshape.fill"
        case .internetPlugins: "globe"
        case .widgets: "square.grid.2x2.fill"
        }
    }
}

struct UninstallableExtension: Identifiable {
    let url: URL
    let name: String
    let category: ExtensionUninstallCategory
    let size: Int64
    var id: String { url.standardizedFileURL.path }
}

enum ExtensionUninstaller {
    private static let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)

    static func scan() -> [UninstallableExtension] {
        ExtensionUninstallCategory.allCases.flatMap(scan(category:))
    }

    static func scan(category: ExtensionUninstallCategory) -> [UninstallableExtension] {
        switch category {
        case .installers:
            let roots = ["Downloads", "Desktop"].map { home.appendingPathComponent($0, isDirectory: true) }
            return directChildren(in: roots, category: category) {
                ["pkg", "mpkg", "dmg", "xip"].contains($0.pathExtension.lowercased())
            }
        case .browserExtensions:
            return scanBrowserExtensions()
        case .screenSavers:
            return directChildren(in: [home.appendingPathComponent("Library/Screen Savers", isDirectory: true)], category: category)
        case .preferencePanes:
            return directChildren(in: [home.appendingPathComponent("Library/PreferencePanes", isDirectory: true)], category: category)
        case .internetPlugins:
            return directChildren(in: [home.appendingPathComponent("Library/Internet Plug-Ins", isDirectory: true)], category: category)
        case .widgets:
            return directChildren(in: [home.appendingPathComponent("Library/Widgets", isDirectory: true)], category: category)
        }
    }

    static func prepareUninstall(_ items: [UninstallableExtension]) -> FileOperationPlan {
        let groups = Dictionary(grouping: items, by: \.category)
        var plans: [FileOperationPlan] = []
        for (category, group) in groups {
            plans.append(FileOperationPlan.prepare(urls: group.map(\.url), roots: roots(for: category)))
        }
        return FileOperationPlan(items: plans.flatMap(\.items), rejected: plans.flatMap(\.rejected))
    }

    private static func roots(for category: ExtensionUninstallCategory) -> [URL] {
        switch category {
        case .installers:
            return ["Downloads", "Desktop"].map { home.appendingPathComponent($0, isDirectory: true) }
        case .browserExtensions:
            return browserExtensionRoots()
        case .screenSavers:
            return [home.appendingPathComponent("Library/Screen Savers", isDirectory: true)]
        case .preferencePanes:
            return [home.appendingPathComponent("Library/PreferencePanes", isDirectory: true)]
        case .internetPlugins:
            return [home.appendingPathComponent("Library/Internet Plug-Ins", isDirectory: true)]
        case .widgets:
            return [home.appendingPathComponent("Library/Widgets", isDirectory: true)]
        }
    }

    private static func directChildren(in roots: [URL], category: ExtensionUninstallCategory,
                                       matching: (URL) -> Bool = { _ in true }) -> [UninstallableExtension] {
        let manager = FileManager.default
        return roots.flatMap { root -> [UninstallableExtension] in
            guard let urls = try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
            return urls.filter(matching).compactMap { url in
                guard let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
                let name = url.deletingPathExtension().lastPathComponent
                return UninstallableExtension(url: url, name: name, category: category,
                                              size: ApplicationUninstaller.diskSize(url))
            }
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func browserExtensionRoots() -> [URL] {
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let browserNames = [
            "Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge",
            "Chromium", "Vivaldi", "com.operasoftware.Opera", "Arc/User Data"
        ]
        let manager = FileManager.default
        var roots: [URL] = []
        for browserName in browserNames {
            let browserRoot = support.appendingPathComponent(browserName, isDirectory: true)
            guard let profiles = try? manager.contentsOfDirectory(at: browserRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            roots += profiles.map { $0.appendingPathComponent("Extensions", isDirectory: true) }
        }
        roots.append(home.appendingPathComponent("Library/Safari/Extensions", isDirectory: true))
        roots.append(home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/Extensions", isDirectory: true))
        roots.append(home.appendingPathComponent("Library/Containers/com.apple.Safari/Data/Library/Safari/AppExtensions", isDirectory: true))
        let firefoxProfiles = home.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        if let profiles = try? manager.contentsOfDirectory(at: firefoxProfiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            roots += profiles.map { $0.appendingPathComponent("extensions", isDirectory: true) }
        }
        return roots.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func scanBrowserExtensions() -> [UninstallableExtension] {
        let manager = FileManager.default
        var result = directChildren(in: browserExtensionRoots(), category: .browserExtensions) {
            ["safariextz", "appex", "xpi"].contains($0.pathExtension.lowercased())
        }
        let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        let chromiumRoots = [
            "Google/Chrome", "BraveSoftware/Brave-Browser", "Microsoft Edge",
            "Chromium", "Vivaldi", "com.operasoftware.Opera", "Arc/User Data"
        ].map { support.appendingPathComponent($0, isDirectory: true) }
        for browserRoot in chromiumRoots where manager.fileExists(atPath: browserRoot.path) {
            guard let profiles = try? manager.contentsOfDirectory(at: browserRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
            for profile in profiles {
                let extensionRoot = profile.appendingPathComponent("Extensions", isDirectory: true)
                guard let extensionIDs = try? manager.contentsOfDirectory(at: extensionRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                for extensionID in extensionIDs {
                    guard let versions = try? manager.contentsOfDirectory(at: extensionID, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]),
                          let version = versions.first(where: { manager.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) }) else { continue }
                    let name = manifestName(at: version.appendingPathComponent("manifest.json")) ?? extensionID.lastPathComponent
                    result.append(UninstallableExtension(url: extensionID, name: name, category: .browserExtensions,
                                                         size: ApplicationUninstaller.diskSize(extensionID)))
                }
            }
        }
        let firefoxProfiles = home.appendingPathComponent("Library/Application Support/Firefox/Profiles", isDirectory: true)
        if let profiles = try? manager.contentsOfDirectory(at: firefoxProfiles, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for profile in profiles {
                result += directChildren(in: [profile.appendingPathComponent("extensions", isDirectory: true)], category: .browserExtensions) {
                    var isDirectory = ObjCBool(false)
                    return ["xpi"].contains($0.pathExtension.lowercased())
                        || (manager.fileExists(atPath: $0.path, isDirectory: &isDirectory) && isDirectory.boolValue)
                }
            }
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0.id).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func manifestName(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = manifest["name"] as? String,
              !name.hasPrefix("__MSG_"), !name.isEmpty else { return nil }
        return name
    }
}

struct UninstallItem: Identifiable {
    let url: URL
    let size: Int64
    var id: String { url.path }
}

struct StartupItem: Identifiable {
    let url: URL
    let label: String
    let program: String
    let kind: String
    let startupStatus: String
    var repairData: Data? = nil
    var repairAdvice: String = "建议重新安装所属应用或联系开发者检查配置；不要猜测程序路径或修改执行权限。"
    var id: String { url.path }
}

enum StartupItemRepair {
    static func quarantine(_ item: StartupItem, backupRoot: URL? = nil, userLaunchRoot: URL? = nil) throws -> URL {
        let fm = FileManager.default
        let allowedRoot = userLaunchRoot ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/LaunchAgents")
        guard item.url.deletingLastPathComponent().standardizedFileURL == allowedRoot.standardizedFileURL,
              allowedRoot.resolvingSymlinksInPath() == allowedRoot.standardizedFileURL,
              let expected = item.repairData,
              try fm.attributesOfItem(atPath: item.url.path)[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: item.url) == expected else {
            throw NSError(domain: "StartupItemRepair", code: 1, userInfo: [NSLocalizedDescriptionKey: "配置已变化或不支持自动处理，请重新扫描。"])
        }
        if let plist = (try? PropertyListSerialization.propertyList(from: expected, format: nil)) as? [String: Any] {
            let program = plist["Program"] as? String ?? (plist["ProgramArguments"] as? [String])?.first ?? ""
            guard program.hasPrefix("/"), !fm.fileExists(atPath: program) else {
                throw NSError(domain: "StartupItemRepair", code: 3, userInfo: [NSLocalizedDescriptionKey: "执行程序已恢复或异常原因不支持自动处理，请重新扫描。"])
            }
        }
        let root = backupRoot ?? fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AILock/StartupItemBackups", isDirectory: true)
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let backup = folder.appendingPathComponent(item.url.lastPathComponent)
        try expected.write(to: backup, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
        try Data(item.url.path.utf8).write(to: folder.appendingPathComponent("original-path.txt"))
        // Recheck immediately before removal; keep the backup on any failure.
        guard try fm.attributesOfItem(atPath: item.url.path)[.type] as? FileAttributeType == .typeRegular,
              try Data(contentsOf: item.url) == expected else {
            throw NSError(domain: "StartupItemRepair", code: 2, userInfo: [NSLocalizedDescriptionKey: "配置在备份期间发生变化，原文件保留。备份：\(backup.path)"])
        }
        try fm.removeItem(at: item.url)
        return backup
    }
}

enum ApplicationUninstaller {
    static func scan() -> [InstalledApplication] {
        ApplicationCatalog.scan(roots: ApplicationLocations.removableRoots).map {
            InstalledApplication(url: $0.url, name: $0.title, bundleID: $0.bundleID, size: diskSize($0.url))
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Publish names/icons first; expensive bundle size traversal follows separately.
    static func scanIncrementally(onBatch: ([InstalledApplication]) -> Void) {
        var apps: [InstalledApplication] = []
        var batch: [InstalledApplication] = []
        var lastDelivery = Date.distantPast
        func flush() {
            guard !batch.isEmpty else { return }
            onBatch(batch)
            batch.removeAll(keepingCapacity: true)
            lastDelivery = Date()
        }
        ApplicationCatalog.enumerateApplications(roots: ApplicationLocations.removableRoots) { url, name, bundleID in
            let app = InstalledApplication(url: url, name: name, bundleID: bundleID, size: 0, sizeIsCalculated: false)
            apps.append(app); batch.append(app)
            if batch.count >= 12 || Date().timeIntervalSince(lastDelivery) >= 0.1 { flush() }
        }
        flush()
        for app in apps {
            batch.append(InstalledApplication(url: app.url, name: app.name, bundleID: app.bundleID, size: diskSize(app.url)))
            if batch.count >= 12 || Date().timeIntervalSince(lastDelivery) >= 0.1 { flush() }
        }
        flush()
    }

    static func relatedItems(for app: InstalledApplication) -> [UninstallItem] {
        guard app.bundleID.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil, app.bundleID.contains(".") else { return [] }
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
                candidates += urls.filter { $0.lastPathComponent == app.bundleID }
            }
        }
        return candidates.compactMap { url in
            guard ApplicationLocations.canonicalURL(url).path.hasPrefix(ApplicationLocations.canonicalURL(home).path + "/Library/"), isInside(url, root: home), manager.fileExists(atPath: url.path), let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink != true else { return nil }
            return UninstallItem(url: url, size: diskSize(url))
        }
    }

    struct UninstallPlan {
        let app: InstalledApplication
        let application: FileOperationPlan
        let related: FileOperationPlan
        func execute() -> [FileActionResult] {
            guard Bundle(url: app.url)?.bundleIdentifier == app.bundleID,
                  !NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL == app.url.standardizedFileURL }) else {
                return [FileActionResult(url: app.url, destination: nil, error: "应用身份已改变或应用仍在运行，请退出后重试")]
            }
            let result = application.execute()
            guard result.count == 1, result[0].succeeded else { return result }
            return result + related.execute()
        }
    }

    static func prepareUninstall(_ app: InstalledApplication, relatedItems: [UninstallItem]) -> UninstallPlan {
        let roots = ApplicationLocations.removableRoots
        var application = FileOperationPlan.prepare(urls: [app.url], roots: roots)
        if app.url.pathExtension != "app" || app.url.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath()
            || Bundle(url: app.url)?.bundleIdentifier != app.bundleID {
            application = FileOperationPlan(items: [], rejected: [FileActionResult(url: app.url, destination: nil, error: "拒绝卸载系统、自身或身份不匹配的应用")])
        }
        let allowed = Set(Self.relatedItems(for: app).map { $0.url.standardizedFileURL.path })
        let library = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
        let accepted = relatedItems.filter { allowed.contains($0.url.standardizedFileURL.path) }
        let plan = FileOperationPlan.prepare(urls: accepted.map(\.url), roots: [library])
        let rejected = relatedItems.filter { !allowed.contains($0.url.standardizedFileURL.path) }
            .map { FileActionResult(url: $0.url, destination: nil, error: "未验证该资源属于此应用") }
        return UninstallPlan(app: app, application: application, related: FileOperationPlan(items: plan.items, rejected: plan.rejected + rejected))
    }

    static func uninstall(_ app: InstalledApplication, relatedItems: [UninstallItem]) -> Bool {
        prepareUninstall(app, relatedItems: relatedItems).execute().allSatisfy(\.succeeded)
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        ApplicationLocations.contains(url, in: root)
    }

    static func diskSize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey]
        if let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return 0 }
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
        FileScanService.scan(root: root, threshold: threshold).largestFiles
    }
    static func categories(in root: URL) -> [StorageCategory] {
        // Categories intentionally summarize every accessible file in the snapshot.
        FileScanService.scan(root: root, limit: 0).categories
    }
}

enum StartupItemInspector {
    static func scan(roots: [(URL, String)]? = nil) -> [StartupItem] {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let directories = roots ?? [
            (home.appendingPathComponent("Library/LaunchAgents"), "当前用户 LaunchAgent"),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), "系统 LaunchAgent"),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), "系统 LaunchDaemon")
        ]
        var result: [StartupItem] = []
        for (root, kind) in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for file in files where file.pathExtension == "plist" {
                let fallback = file.deletingPathExtension().lastPathComponent
                guard (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                    result.append(StartupItem(url: file, label: fallback, program: "未验证", kind: kind, startupStatus: "符号链接配置，未读取 · 运行状态未知")); continue
                }
                guard let data = try? Data(contentsOf: file), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
                    var item = StartupItem(url: file, label: fallback, program: "未知", kind: kind, startupStatus: "配置无法解析 · 运行状态未知")
                    if root.standardizedFileURL == home.appendingPathComponent("Library/LaunchAgents").standardizedFileURL,
                       let data = try? Data(contentsOf: file) {
                        item.repairData = data
                        item.repairAdvice = "配置无法解析，可备份后移走；如需恢复，将备份复制回原路径，并通过所属应用重新启用。"
                    } else { item.repairAdvice = "配置无法读取或解析，请通过所属应用修复；系统配置需管理员处理。" }
                    result.append(item); continue
                }
                let args = plist["ProgramArguments"] as? [String] ?? []
                let label = plist["Label"] as? String ?? fallback
                let program = plist["Program"] as? String ?? args.first ?? ""
                let executable = program.hasPrefix("/") ? program : ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                    .map { $0 + "/" + program }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? program
                var problems: [String] = []
                if (plist["Label"] as? String)?.isEmpty != false { problems.append("缺少有效 Label") }
                if program.isEmpty { problems.append("缺少执行程序") }
                else if !FileManager.default.fileExists(atPath: executable) { problems.append("程序不存在") }
                else if !FileManager.default.isExecutableFile(atPath: executable) { problems.append("程序执行权限未确认") }
                let trigger: String
                if plist["Disabled"] as? Bool == true { trigger = "配置为禁用" }
                else if plist["RunAtLoad"] as? Bool == true { trigger = "加载时启动" }
                else if plist["KeepAlive"] as? Bool == true { trigger = "保持运行" }
                else if plist["StartInterval"] != nil || plist["StartCalendarInterval"] != nil { trigger = "定时触发" }
                else if plist["MachServices"] != nil || plist["KeepAlive"] is [String: Any] || plist["WatchPaths"] != nil || plist["QueueDirectories"] != nil { trigger = "按需触发" }
                else { trigger = "手动/其他触发" }
                let status = ([trigger] + problems + ["运行状态未知"]).joined(separator: " · ")
                var item = StartupItem(url: file, label: label, program: executable.isEmpty ? "未知" : executable, kind: kind, startupStatus: status)
                if problems.isEmpty { item.repairAdvice = "未发现配置异常，无需修复。运行状态尚未验证。" }
                else if !program.isEmpty && program.hasPrefix("/") && !FileManager.default.fileExists(atPath: executable) {
                    item.repairAdvice = "执行程序不存在。建议先重新安装所属应用；确认不再使用时，可备份后移走配置。"
                    if root.standardizedFileURL == home.appendingPathComponent("Library/LaunchAgents").standardizedFileURL { item.repairData = data }
                }
                result.append(item)
            }
        }
        return result.sorted { $0.kind == $1.kind ? $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending : $0.kind < $1.kind }
    }
}


// Short, local benchmarks run once when the Mac health view first opens.
enum HardwareBenchmark: String, CaseIterable, Identifiable, Sendable {
    case disk, memory, localAI
    var id: String { rawValue }
    var title: String {
        switch self {
        case .disk: return "硬盘读写测试"
        case .memory: return "内存读写测试"
        case .localAI: return "本地 AI 能力"
        }
    }
    var symbol: String {
        switch self {
        case .disk: return "internaldrive"
        case .memory: return "memorychip"
        case .localAI: return "cpu"
        }
    }
    var detail: String {
        switch self {
        case .disk: return "在临时目录顺序读写 256 MiB，结束后自动删除。结果受文件系统与缓存影响。"
        case .memory: return "使用两个 32 MiB 缓冲区测试写入与复制带宽，包含 CPU 与缓存影响。"
        case .localAI: return "运行短时 CPU 与 Metal GPU 计算基准，并按系统内存估算可装载的量化模型规模。实际速度与模型、上下文长度和运行时有关。"
        }
    }
    func run() throws -> [(String, String)] {
        switch self {
        case .disk: return try disk()
        case .memory: return try memory()
        case .localAI: return try LocalAIHardwareBenchmark.run()
        }
    }
    private func rate(_ bytes: Int, since start: UInt64) -> String {
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return String(format: "%.1f MB/s", Double(bytes) / max(seconds, 0.000001) / 1_000_000)
    }
    private func disk() throws -> [(String, String)] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-benchmark-" + UUID().uuidString)
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd); try? FileManager.default.removeItem(at: url) }
        guard fcntl(fd, F_NOCACHE, 1) != -1 else { throw POSIXError(.EIO) }
        let chunk = 4 * 1024 * 1024, count = 64
        var buffer = [UInt8](repeating: 0, count: chunk)
        buffer.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, chunk) }
        let writeStart = DispatchTime.now().uptimeNanoseconds
        try buffer.withUnsafeBytes { raw in
            for _ in 0..<count {
                try Task.checkCancellation()
                var offset = 0
                while offset < chunk {
                    let n = Darwin.write(fd, raw.baseAddress!.advanced(by: offset), chunk - offset)
                    guard n > 0 else { throw POSIXError(.EIO) }; offset += n
                }
            }
        }
        guard fsync(fd) == 0 else { throw POSIXError(.EIO) }
        let writeRate = rate(chunk * count, since: writeStart)
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw POSIXError(.EIO) }
        let readStart = DispatchTime.now().uptimeNanoseconds
        try buffer.withUnsafeMutableBytes { raw in
            for _ in 0..<count {
                try Task.checkCancellation()
                var offset = 0
                while offset < chunk {
                    let n = Darwin.read(fd, raw.baseAddress!.advanced(by: offset), chunk - offset)
                    guard n > 0 else { throw POSIXError(.EIO) }; offset += n
                }
            }
        }
        return [("顺序写入", writeRate), ("顺序读取", rate(chunk * count, since: readStart))]
    }
    private func memory() throws -> [(String, String)] {
        let bytes = 32 * 1024 * 1024, iterations = 32
        let source = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        let target = UnsafeMutableRawPointer.allocate(byteCount: bytes, alignment: 64)
        defer { source.deallocate(); target.deallocate() }
        memset(source, 0x55, bytes); memset(target, 0, bytes)
        let start = DispatchTime.now().uptimeNanoseconds
        var checksum: UInt64 = 0
        for i in 0..<iterations {
            try Task.checkCancellation()
            memset(source, Int32(i), bytes)
            for offset in stride(from: 0, to: bytes, by: 4096) {
                checksum &+= UInt64(source.load(fromByteOffset: offset, as: UInt8.self))
            }
        }
        let writeRate = rate(bytes * iterations, since: start)
        let copyStart = DispatchTime.now().uptimeNanoseconds
        for _ in 0..<iterations {
            try Task.checkCancellation()
            memcpy(target, source, bytes)
            // Observe copied bytes so optimized builds retain the copy work.
            for offset in stride(from: 0, to: bytes, by: 4096) { checksum &+= UInt64(target.load(fromByteOffset: offset, as: UInt8.self)) }
        }
        guard target.load(as: UInt8.self) == UInt8(iterations - 1) else { throw POSIXError(.EIO) }
        return [("内存写入", writeRate), ("内存复制（读取＋写入）", rate(bytes * iterations, since: copyStart)), ("校验值", String(checksum))]
    }
}

private enum LocalAIHardwareBenchmark {
    private static let itemCount = 262_144
    private static let memoryBudgetRatio = 0.72

    static func run() throws -> [(String, String)] {
        try Task.checkCancellation()
        let cpuRate = try cpuThroughput()
        try Task.checkCancellation()
        let gpu = gpuThroughput()
        let totalMemory = ProcessInfo.processInfo.physicalMemory
        // Reserve memory for macOS, the application, and the model's KV cache.
        let modelBudgetGB = Double(totalMemory) * memoryBudgetRatio / 1_000_000_000
        let fourBit = Int(modelBudgetGB / 1.0)
        let eightBit = Int(modelBudgetGB / 1.5)
        let fp16 = Int(modelBudgetGB / 2.5)
        return [
            ("CPU计算", cpuRate),
            ("GPU设备", gpu.name),
            ("GPU计算", gpu.rate),
            ("系统内存", ByteCountFormatter.string(fromByteCount: Int64(totalMemory), countStyle: .memory)),
            ("4-bit模型", L10n.format("约 %{0}B 参数", arguments: [String(fourBit)])),
            ("8-bit模型", L10n.format("约 %{0}B 参数", arguments: [String(eightBit)])),
            ("FP16模型", L10n.format("约 %{0}B 参数", arguments: [String(fp16)]))
        ]
    }

    private static func cpuThroughput() throws -> String {
        let iterations = 64
        var a = [SIMD4<Float>](repeating: SIMD4(1, 2, 3, 4), count: itemCount / 4)
        let b = [SIMD4<Float>](repeating: SIMD4(0.25, 0.5, 0.75, 1), count: itemCount / 4)
        var checksum: Float = 0
        let start = DispatchTime.now().uptimeNanoseconds
        for iteration in 0..<iterations {
            try Task.checkCancellation()
            let scale = Float(iteration + 1)
            for index in a.indices {
                a[index] = a[index] * b[index] + SIMD4(repeating: scale)
            }
            checksum += a[iteration % a.count].x
        }
        guard checksum.isFinite else { throw POSIXError(.EIO) }
        let seconds = max(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000, 0.000001)
        let operations = Double(itemCount) * Double(iterations) * 2
        return String(format: "%.1f GFLOP/s", operations / seconds / 1_000_000_000)
    }

    private static func gpuThroughput() -> (name: String, rate: String) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: """
                #include <metal_stdlib>
                using namespace metal;
                kernel void ailockCompute(device float *values [[buffer(0)]],
                                           constant uint &count [[buffer(1)]],
                                           uint index [[thread_position_in_grid]]) {
                    if (index < count) {
                        float value = values[index];
                        for (uint i = 0; i < 128; i++) {
                            value = fma(value, 1.000001f, 0.000001f);
                        }
                        values[index] = value;
                    }
                }
                """, options: nil),
              let function = library.makeFunction(name: "ailockCompute"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let values = device.makeBuffer(length: itemCount * MemoryLayout<Float>.size, options: .storageModeShared),
              let count = device.makeBuffer(length: MemoryLayout<UInt32>.size, options: .storageModeShared) else {
            return (MTLCreateSystemDefaultDevice()?.name ?? "GPU 不可用", "不可用")
        }

        values.contents().bindMemory(to: Float.self, capacity: itemCount).initialize(repeating: 1, count: itemCount)
        count.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = UInt32(itemCount)
        let iterations = 8
        let start = DispatchTime.now().uptimeNanoseconds
        var lastCommand: MTLCommandBuffer?
        for _ in 0..<iterations {
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
                return (device.name, "不可用")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(values, offset: 0, index: 0)
            encoder.setBuffer(count, offset: 0, index: 1)
            let width = min(pipeline.threadExecutionWidth * 8, itemCount)
            encoder.dispatchThreads(MTLSize(width: itemCount, height: 1, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
            encoder.endEncoding()
            lastCommand = command
            command.commit()
        }
        // Wait for the final submitted work before stopping the timer.
        lastCommand?.waitUntilCompleted()
        guard lastCommand?.status == .completed else { return (device.name, "不可用") }
        let seconds = max(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000, 0.000001)
        let operations = Double(itemCount) * Double(iterations) * 128 * 2
        return (device.name, String(format: "%.1f GFLOP/s", operations / seconds / 1_000_000_000))
    }
}
