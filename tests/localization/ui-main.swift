import AppKit
import SwiftUI
import CryptoKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let defaults = UserDefaults.standard
let keys = ["overview.language", "overview.followSystemLanguage", "preferences.selectedSection"]
let previous = keys.map { defaults.object(forKey: $0) }
defer {
    for (key, value) in zip(keys, previous) {
        if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}
defaults.set(false, forKey: keys[1])
defaults.set(false, forKey: keys[0])
let label = LocalizedLabel(labelWithString: "监控预警")
let button = LocalizedButton(checkboxWithTitle: "暂停采集", target: nil, action: nil)
let help = DelayedHelpButton(title: "刷新", target: nil, action: nil)
let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: root) }
let history = ClipboardHistory(fileURL: root.appendingPathComponent("history.bin"), defaults: UserDefaults(suiteName: UUID().uuidString)!, pasteboard: .withUniqueName(), keyProvider: { SymmetricKey(size: .bits256) })
let modules: [DashboardWindow.Module] = [.menuBarOrganizer, .files, .processes, .network, .networkDiagnostics, .clipboard, .logs, .settings, .preferences, .dockLock, .search, .cacheCleaner, .uninstaller, .launchItems, .launcher, .screenRecorder, .displayBrightness]
let controllers = modules.map { DashboardWindow(module: $0, registerServices: false, clipboardHistory: history) }
let originalViews = controllers.map { $0.window!.contentView! }
func accessibleStrings(_ element: Any, depth: Int = 0) -> [String] {
    guard depth < 30, let node = element as? NSObject else { return [] }
    func property(_ name: String) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
    var values = ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { property($0) as? String }
    for child in property("accessibilityChildren") as? [Any] ?? [] { values += accessibleStrings(child, depth: depth + 1) }
    if let view = node as? NSView { for child in view.subviews { values += accessibleStrings(child, depth: depth + 1) } }
    return values
}

func save(_ window: NSWindow, name: String) throws {
    guard let view = window.contentView, let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Missing content") }
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.white.cgColor
    view.cacheDisplay(in: view.bounds, to: image)
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/ailock-language-" + name + ".png"))
}
let quickActions = QuickActionWindowController()
func editableField(_ view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    return view.subviews.compactMap(editableField).first
}
for english in [true, false, true] {
    defaults.set(english, forKey: keys[0])
    NotificationCenter.default.post(name: L10n.changed, object: nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(L10n.text("程序坞锁定") == (english ? "Dock Lock" : "程序坞锁定"))
    precondition(L10n.text("剪贴板记录") == (english ? "Clipboard Record" : "剪贴板记录"))
    precondition(L10n.format("已遮罩 %{0} / %{1} 块", arguments: ["1", "2"]) == (english ? "1 of 2 displays covered" : "已遮罩 1 / 2 块"))
    precondition(L10n.text("中文用户内容保持原样") == "中文用户内容保持原样", "Unknown user content must not be translated")
    let quickSearch = editableField(quickActions.window!.contentView!)!
    quickSearch.stringValue = "https://example.com"
    quickActions.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: quickSearch))
    quickActions.window!.contentView!.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    precondition(quickActions.window!.title == L10n.text("快捷操作"))
    precondition(quickSearch.placeholderString == L10n.text("搜应用/文件 · >命令在终端运行 · 网址在浏览器打开"))
    let quickLabels = accessibleStrings(quickActions.window!.contentView!)
    if english { precondition(quickLabels.allSatisfy { $0.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) == nil }, "Chinese quick action UI: \(quickLabels)") }
    let textRecord = ClipboardRecord(sourceBundleID: "localization.fixture", items: [[NSPasteboard.PasteboardType.string.rawValue: Data("设置".utf8)]])
    precondition(ClipboardTagView.displayTitle(for: textRecord) == "设置", "Clipboard user text must never be translated")
    let fileRecord = ClipboardRecord(sourceBundleID: "localization.fixture", items: [[NSPasteboard.PasteboardType.fileURL.rawValue: Data("file:///tmp/测试.txt".utf8)]])
    precondition(ClipboardTagView.displayTitle(for: fileRecord) == L10n.text(fileRecord.preview))
    precondition(L10n.statusList("加载时启动 · 程序不存在 · 运行状态未知") == (english ? "Run at Load · Executable Missing · Runtime Status Unknown" : "加载时启动 · 程序不存在 · 运行状态未知"))
    precondition(label.stringValue == (english ? "Resource Alerts" : "监控预警"))
    precondition(button.title == (english ? "Pause Collection" : "暂停采集"))
    precondition(help.title == (english ? "Refresh" : "刷新"))
    for (index, controller) in controllers.enumerated() {
        let window = controller.window!
        precondition(window.contentView === originalViews[index], "Language changes must preserve the existing page")
        window.appearance = NSAppearance(named: .aqua)
        window.orderFrontRegardless()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        precondition(window.title == (modules[index] == .logs ? L10n.text("AI Lock 应用日志") : L10n.text(modules[index].rawValue)), "Wrong window title for \(modules[index]): \(window.title)")
        let labels = accessibleStrings(window.contentView!)
        let chinese = labels.filter { $0.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil }
        if english && modules[index] != .logs && modules[index] != .preferences && modules[index] != .launchItems && modules[index] != .uninstaller && modules[index] != .cacheCleaner {
            if !chinese.isEmpty { try save(window, name: "debug-" + modules[index].rawValue) }
            precondition(chinese.isEmpty, "Chinese UI in \(modules[index]): \(chinese)")
        }
        if english && [.files, .processes, .network].contains(modules[index]) { try save(window, name: modules[index].rawValue) }
        window.orderOut(nil)
    }
}
defaults.set("通用", forKey: keys[2])
DashboardWindow.openPreferences()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
guard let preferences = app.windows.first(where: { $0.title == "Settings" }) else { fatalError("Settings window not localized") }
preferences.appearance = NSAppearance(named: .aqua)
let labels = accessibleStrings(preferences.contentView!)
let chinese = labels.filter { $0 != "中文" && $0.range(of: #"[\u4e00-\u9fff]"#, options: .regularExpression) != nil }
precondition(chinese.isEmpty, "Chinese settings UI: \(chinese)")
try save(preferences, name: "settings")
try save(preferences, name: "General")
// SwiftUI's virtual accessibility tree is not exposed to this standalone test process.
// Set each stored section directly so this test does not depend on sidebar geometry.
for (section, sectionValue) in [("Resource Alerts", "预警阈值"), ("System Extensions", "系统扩展"), ("DockLock", "程序坞锁定"), ("Home Icons", "首页图标"), ("Keyboard Shortcuts", "快捷键"), ("Help-About", "关于")] {
    defaults.set(sectionValue, forKey: keys[2])
    RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    preferences.contentView?.layoutSubtreeIfNeeded()
    try save(preferences, name: section)
}
print("PASS: native controls, retained module windows and settings switch Chinese/English in place")
