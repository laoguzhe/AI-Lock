import Foundation

enum SettingValue {
    static func validated(_ value: Double, key: String) -> Double? {
        guard value.isFinite else { return nil }
        let range: ClosedRange<Double>
        switch key {
        case "alert.cpu", "alert.memory", "alert.batteryPercent": range = 1...100
        case "alert.thermalLevel": range = 2...3
        case "alert.swapGB": range = 0.1...1_000_000
        case "alert.diskGB": range = 0.1...1_000_000
        case "alert.diskFreePercent": range = 1...100
        case "alert.networkMB": range = 0.1...1_000
        case "edgeMargin": range = 1...100
        default: return nil
        }
        if key == "alert.thermalLevel" && value.rounded() != value { return nil }
        return range.contains(value) ? value : nil
    }

    @discardableResult
    static func saveThresholds(_ values: [(String, Double)], defaults: UserDefaults = .standard) -> Bool {
        guard defaults.integer(forKey: "ailock.settings.schemaVersion") <= 2 else { return false }
        guard values.allSatisfy({ validated($0.1, key: $0.0) != nil }) else { return false }
        values.forEach { defaults.set($0.1, forKey: $0.0) }
        return true
    }

    static func read(_ key: String, fallback: Double, defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: key) != nil,
              let value = validated(defaults.double(forKey: key), key: key) else { return fallback }
        return value
    }
}

struct AlertThresholds: Codable, Equatable {
    var cpu = 90.0
    var memory = 80.0
    var diskFreePercent = 10.0
    var networkMB = 50.0
    // Retained for decoding existing settings data; swap alerts are no longer used.
    var swapGB = 4.0
    var batteryPercent = 20.0
    var thermalLevel = 2.0
}

/// Stable identifiers are persisted; translated UI titles are presentation only.
final class AppSettings {
    static let shared = AppSettings()
    enum Appearance: String { case system, light, dark }
    enum SearchHotkey: String {
        case optionSpace, controlSpace, commandOptionSpace
        var title: String { switch self { case .optionSpace: return "⌥ Space"; case .controlSpace: return "⌃ Space"; case .commandOptionSpace: return "⌘⌥ Space" } }
        init(title: String) { self = title == "⌃ Space" ? .controlSpace : title == "⌘⌥ Space" ? .commandOptionSpace : .optionSpace }
    }
    static let moduleNames: [String: String] = ["files": "安全活动", "processes": "进程管理", "network": "网络活动", "networkDiagnostics": "网络诊断", "logs": "系统日志", "clipboard": "剪贴板历史", "settings": "监控预警", "preferences": "设置", "dockLock": "DockLock", "menuBarOrganizer": "菜单栏收纳", "search": "快速文件搜索", "cacheCleaner": "系统健康检查", "uninstaller": "应用卸载", "launchItems": "启动项检查", "launcher": "快捷操作", "screenRecorder": "录屏工具", "displayBrightness": "显示器控制"]
    private let defaults: UserDefaults
    private let versionKey = "ailock.settings.schemaVersion"
    var supportsWrites: Bool { defaults.integer(forKey: versionKey) <= 2 }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let version = defaults.integer(forKey: versionKey)
        guard version < 2 else { return }
        if version == 0 {
            if let legacy = defaults.dictionary(forKey: "overview.hotkeys") as? [String: Int] {
                var migrated: [String: Int] = [:]
                for (id, name) in Self.moduleNames { if let value = legacy[name] { migrated[id] = value } }
                if migrated["logs"] == nil { migrated["logs"] = legacy["应用日志"] }
                defaults.set(migrated, forKey: "overview.hotkeys.v1")
            }
            defaults.set(SearchHotkey(title: defaults.string(forKey: "search.hotkey") ?? "⌥ Space").rawValue, forKey: "search.hotkey.v1")
        }
        for (legacy, stable) in [("overview.visibleModules", "overview.visibleModules.v1"), ("overview.moduleOrder", "overview.moduleOrder.v1")] {
            if defaults.object(forKey: stable) == nil, let raw = defaults.string(forKey: legacy), !raw.isEmpty {
                defaults.set(Self.stableModuleCSV(raw), forKey: stable)
            }
        }
        if defaults.object(forKey: "overview.fontScale.v1") == nil {
            let legacy = defaults.object(forKey: "overview.fontSize") as? Double ?? 1
            let scale = legacy > 3 ? legacy / 13 : legacy
            defaults.set(scale.isFinite ? min(1.4, max(0.8, scale)) : 1, forKey: "overview.fontScale.v1")
        }
        defaults.set(2, forKey: versionKey)
    }
    static func stableModuleCSV(_ titles: String) -> String {
        let identifiers = titles.split(separator: ",").compactMap { title -> String? in
            if title == "应用日志" { return "logs" }
            if title == "文件活动" { return "files" }
            if title == "DockLock 设置" { return "dockLock" }
            return moduleNames.first { $0.value == title || $0.key == title }.map(\.key)
        }
        var seen = Set<String>()
        return identifiers.filter { seen.insert($0).inserted }.joined(separator: ",")
    }
    static func moduleTitleCSV(_ identifiers: String) -> String {
        if identifiers == "__none__" { return identifiers }
        return identifiers.split(separator: ",").compactMap { moduleNames[String($0)] }.joined(separator: ",")
    }
    var visibleModuleIDs: [String]? {
        get { guard let raw = defaults.string(forKey: "overview.visibleModules.v1"), !raw.isEmpty else { return nil }; return raw.split(separator: ",").map(String.init).filter { Self.moduleNames[$0] != nil } }
        set { guard supportsWrites else { return }; defaults.set(newValue.map { $0.isEmpty ? "__none__" : $0.filter { Self.moduleNames[$0] != nil }.joined(separator: ",") } ?? "", forKey: "overview.visibleModules.v1") }
    }
    var orderedModuleIDs: [String] {
        get { (defaults.string(forKey: "overview.moduleOrder.v1") ?? "").split(separator: ",").map(String.init).filter { Self.moduleNames[$0] != nil } }
        set { guard supportsWrites else { return }; defaults.set(newValue.filter { Self.moduleNames[$0] != nil }.joined(separator: ","), forKey: "overview.moduleOrder.v1") }
    }
    var fontScale: Double {
        get { let value = defaults.object(forKey: "overview.fontScale.v1") as? Double ?? 1; return value.isFinite ? min(1.4, max(0.8, value)) : 1 }
        set { guard supportsWrites, newValue.isFinite, (0.8...1.4).contains(newValue) else { return }; defaults.set(newValue, forKey: "overview.fontScale.v1") }
    }
    var alerts: AlertThresholds {
        get {
            let legacyDisk = SettingValue.read("alert.diskGB", fallback: 10, defaults: defaults)
            let legacyDiskPercent = legacyDisk <= 100 ? max(1, legacyDisk) : 10
            return AlertThresholds(cpu: SettingValue.read("alert.cpu", fallback: 90, defaults: defaults),
                                   memory: SettingValue.read("alert.memory", fallback: 80, defaults: defaults),
                                   diskFreePercent: SettingValue.read("alert.diskFreePercent", fallback: legacyDiskPercent, defaults: defaults),
                                   networkMB: SettingValue.read("alert.networkMB", fallback: 50, defaults: defaults),
                                   swapGB: SettingValue.read("alert.swapGB", fallback: 4, defaults: defaults),
                                   batteryPercent: SettingValue.read("alert.batteryPercent", fallback: 20, defaults: defaults),
                                   thermalLevel: SettingValue.read("alert.thermalLevel", fallback: 2, defaults: defaults))
        }
    }
    @discardableResult func saveAlerts(_ value: AlertThresholds) -> Bool {
        supportsWrites && SettingValue.saveThresholds([("alert.cpu", value.cpu), ("alert.memory", value.memory), ("alert.diskFreePercent", value.diskFreePercent), ("alert.networkMB", value.networkMB), ("alert.batteryPercent", value.batteryPercent), ("alert.thermalLevel", value.thermalLevel)], defaults: defaults)
    }
    var appearance: Appearance { Appearance(rawValue: defaults.string(forKey: "appearance.mode") ?? "system") ?? .system }
    var moduleHotkeys: [String: Int] {
        get { defaults.dictionary(forKey: "overview.hotkeys.v1") as? [String: Int] ?? ["files": 1, "processes": 2, "network": 3, "logs": 4, "clipboard": 5, "settings": 6, "cacheCleaner": 7, "preferences": 8, "launcher": 9] }
        set {
            guard supportsWrites, newValue.keys.allSatisfy({ Self.moduleNames[$0] != nil }), newValue.values.allSatisfy({ (0...9).contains($0) }) else { return }
            defaults.set(newValue, forKey: "overview.hotkeys.v1")
            defaults.set(Dictionary(uniqueKeysWithValues: newValue.compactMap { id, number in Self.moduleNames[id].map { ($0, number) } }), forKey: "overview.hotkeys")
        }
    }
    var searchHotkey: SearchHotkey {
        get { SearchHotkey(rawValue: defaults.string(forKey: "search.hotkey.v1") ?? "") ?? SearchHotkey(title: defaults.string(forKey: "search.hotkey") ?? "⌥ Space") }
        set { guard supportsWrites else { return }; defaults.set(newValue.rawValue, forKey: "search.hotkey.v1"); defaults.set(newValue.title, forKey: "search.hotkey") }
    }
    var clipboardRetentionDays: Int {
        get { min(30, max(1, defaults.object(forKey: "clipboard.retentionDays") as? Int ?? 3)) }
        set { guard supportsWrites else { return }; defaults.set(min(30, max(1, newValue)), forKey: "clipboard.retentionDays") }
    }
    var clipboardPaused: Bool {
        get { defaults.bool(forKey: "clipboard.paused") }
        set { guard supportsWrites else { return }; defaults.set(newValue, forKey: "clipboard.paused") }
    }
    var clipboardExcludedBundleIDs: [String] {
        get { Array(Set(defaults.stringArray(forKey: "clipboard.excludedBundleIDs") ?? [])).sorted() }
        set { guard supportsWrites else { return }; defaults.set(Array(Set(newValue.filter { !$0.isEmpty })).sorted(), forKey: "clipboard.excludedBundleIDs") }
    }
    var clipboardSkipSensitiveContent: Bool {
        get { defaults.object(forKey: "clipboard.skipSensitiveContent") as? Bool ?? true }
        set { guard supportsWrites else { return }; defaults.set(newValue, forKey: "clipboard.skipSensitiveContent") }
    }
    var edgeMargin: Double {
        get { SettingValue.read("edgeMargin", fallback: 6, defaults: defaults) }
        set { guard supportsWrites, let value = SettingValue.validated(newValue, key: "edgeMargin") else { return }; defaults.set(value, forKey: "edgeMargin") }
    }
    var autoSnap: Bool {
        get { defaults.object(forKey: "autoSnap") as? Bool ?? true }
        set { guard supportsWrites else { return }; defaults.set(newValue, forKey: "autoSnap") }
    }
}
