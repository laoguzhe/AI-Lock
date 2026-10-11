import AppKit
import Carbon.HIToolbox
import SwiftUI
import CryptoKit
// Existing UI fixtures assert Chinese titles; isolate them from the user's language choice.
let languageDefaults = UserDefaults.standard
let languageKeys = ["overview.language", "overview.followSystemLanguage"]
let previousLanguageValues = languageKeys.map { languageDefaults.object(forKey: $0) }
defer {
    for (key, value) in zip(languageKeys, previousLanguageValues) {
        if let value { languageDefaults.set(value, forKey: key) } else { languageDefaults.removeObject(forKey: key) }
    }
}
languageDefaults.set(false, forKey: "overview.followSystemLanguage")
languageDefaults.set(false, forKey: "overview.language")
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "launcher-search" {
    let fixture = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-launcher-" + UUID().uuidString)
    let folder = fixture.appendingPathComponent("juece")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: fixture) }
    let controller = QuickActionWindowController(engine: QuickSearch(directoryRoots: [fixture], diskAccessCheck: { true }))
    controller.prepare(); controller.showWindow(nil); controller.window!.makeKeyAndOrderFront(nil); controller.focusSearch()
    let view = controller.window!.contentView!
    let field = view.subviews.compactMap { $0 as? NSTextField }.first!
    func labels(_ view: NSView) -> [String] {
        (view as? NSTextField).map { [$0.stringValue] } ?? view.subviews.flatMap(labels)
    }
    func query(_ value: String) {
        field.stringValue = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        view.layoutSubtreeIfNeeded()
    }
    query("JUECE")
    let deadline = Date().addingTimeInterval(5)
    while !labels(view).contains("juece") && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)); view.layoutSubtreeIfNeeded() }
    precondition(labels(view).contains("juece"), "Unified bar must show the actual folder result")
    precondition(labels(view).contains(where: { $0.contains(folder.path) }), "Results must include a disambiguating path")
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render unified search") }
    view.cacheDisplay(in: view.bounds, to: image)
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    query("https://example.com")
    precondition(labels(view).contains("打开网页"))
    query("> printf hello")
    precondition(labels(view).contains("在终端执行") && labels(view).contains("printf hello"))
    query("")
    precondition(controller.window!.frame.height == 108, "Empty query must collapse back to one search bar")
    controller.close()
    print("PASS: unified search field shows case-insensitive folder with path, URL and command actions, and collapses when cleared")
    exit(0)
}
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "command-gesture" {
    let defaults = UserDefaults.standard
    let previousChoice = defaults.object(forKey: "hotkey.quickAction")
    defaults.set(0, forKey: "hotkey.quickAction")
    defer {
        if let previousChoice { defaults.set(previousChoice, forKey: "hotkey.quickAction") }
        else { defaults.removeObject(forKey: "hotkey.quickAction") }
    }
    // Feed native-shaped events into the same adapter used by the real session tap.
    // Some keyboards include secondaryFn even on modifier-only events.
    for code in [kVK_Command, kVK_RightCommand] {
        for (index, down) in [true, false, true, false].enumerated() {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down)!
            event.type = .flagsChanged
            event.flags = down ? CGEventFlags([.maskCommand, .maskSecondaryFn]) : CGEventFlags.maskSecondaryFn
            event.timestamp = UInt64(10 + code) * 1_000_000_000 + UInt64(index) * 100_000_000
            DashboardWindow.receiveCommandEvent(type: .flagsChanged, event: event)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let panel = app.windows.first(where: { $0.title == "快捷操作" && $0.isVisible }) else { fatalError("Command event path did not open launcher") }
        panel.close()
    }
    print("PASS: left/right native Command events including device Fn flag open launcher through production event adapter")
    exit(0)
}
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "launcher" {
    DashboardWindow.openLauncher()
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let window = app.windows.first(where: { $0.title == "快捷操作" }), let view = window.contentView else { fatalError("Missing launcher") }
    precondition(window.styleMask.contains(.borderless), "Launcher must have no window chrome")
    DashboardWindow.openLauncher()
    precondition(!window.isVisible, "Second invocation must hide the search bar")
    DashboardWindow.openLauncher()
    precondition(window.isVisible, "Third invocation must show the search bar")
    view.layoutSubtreeIfNeeded()
    guard let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render launcher") }
    view.cacheDisplay(in: view.bounds, to: image)
    precondition((image.colorAt(x: 0, y: 0)?.alphaComponent ?? 1) < 0.01, "Outer corners must be transparent")
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    window.close()
    print("PASS: search bar toggles visibility and renders transparent corners")
    exit(0)
}
// Render the actual menu-bar overview at its production popover dimensions.
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "overview" {
    let host = NSHostingView(rootView: DashboardOverviewView())
    let overviewWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 600),
        styleMask: [.borderless], backing: .buffered, defer: false)
    overviewWindow.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: 390, height: 600)
    overviewWindow.orderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    host.layoutSubtreeIfNeeded()
    guard let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("Cannot render overview") }
    host.cacheDisplay(in: host.bounds, to: image)
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    overviewWindow.close()
    print("Rendered overview at 390x600")
    exit(0)
}
let uiRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ailock-ui-history-" + UUID().uuidString)
let uiSuite = "com.laogu.ailock.ui-tests." + UUID().uuidString
let uiDefaults = UserDefaults(suiteName: uiSuite)!
defer { uiDefaults.removePersistentDomain(forName: uiSuite); try? FileManager.default.removeItem(at: uiRoot) }
let uiKey = SymmetricKey(size: .bits256)
let clipboardMode = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "clipboard"
let repositoryURL = uiRoot.appendingPathComponent("history.sqlite")
if clipboardMode {
    let fixture = (0..<225).map { index in
        ClipboardRecord(capturedAt: Date().addingTimeInterval(-Double(index)), sourceBundleID: "ui.fixture", items: [["public.utf8-plain-text": Data("分页测试记录 \(index)".utf8)]])
    }
    try ClipboardRepository(url: repositoryURL).replace(with: fixture, key: uiKey)
}
let uiPasteboard = NSPasteboard.withUniqueName()
let history = ClipboardHistory(fileURL: uiRoot.appendingPathComponent("history.bin"), defaults: uiDefaults,
    pasteboard: uiPasteboard, keyProvider: { uiKey }, repositoryURL: clipboardMode ? repositoryURL : nil)
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "appearance" {
    let defaults = UserDefaults.standard
    let previousAppearance = defaults.object(forKey: "appearance.mode")
    defer {
        if let previousAppearance { defaults.set(previousAppearance, forKey: "appearance.mode") }
        else { defaults.removeObject(forKey: "appearance.mode") }
    }
    defaults.set("dark", forKey: "appearance.mode")
    let modules: [DashboardWindow.Module] = [.files, .processes, .network, .clipboard, .logs, .settings, .search, .launcher, .cacheCleaner, .uninstaller, .launchItems]
    let controllers = modules.map { DashboardWindow(module: $0, registerServices: false, clipboardHistory: history) }
    let originalViews = controllers.map { $0.window!.contentView! }
    for mode in ["light", "dark", "light", "system"] {
        defaults.set(mode, forKey: "appearance.mode")
        NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        for (index, controller) in controllers.enumerated() {
            let window = controller.window!
            precondition(window.contentView === originalViews[index], "Theme changes must preserve module state")
            if mode == "system" {
                precondition(window.appearance == nil, "System mode must clear the window override")
            } else {
                let expected: NSAppearance.Name = mode == "light" ? .aqua : .darkAqua
                precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "Stale window appearance: \(modules[index])")
                precondition(window.contentView!.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected, "Stale content appearance: \(modules[index])")
            }
        }
    }
    controllers.forEach { $0.window?.close() }
    print("PASS: 11 cached module windows follow repeated theme changes and system mode without replacing content")
    exit(0)
}
let requestedModule: DashboardWindow.Module = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "network" ? .network : CommandLine.arguments.count > 2 && ["processes", "processes-close-confirmation"].contains(CommandLine.arguments[2]) ? .processes : clipboardMode ? .clipboard : .files
let controller = DashboardWindow(module: requestedModule, registerServices: false, clipboardHistory: history)
guard let window = controller.window else { fatalError("Missing window") }
let dockMode = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "dock"
if dockMode {
    let screen = DockLock.ScreenChoice(id: 999, name: "测试显示器", isBuiltin: true, size: "1440×900", bounds: CGRect(x: 0, y: 0, width: 1440, height: 900))
    window.contentViewController = NSHostingController(rootView: VStack(alignment: .leading, spacing: 18) {
        Text("DockLock").font(.title2)
        Text("锁定程序坞在你选择的显示器上。")
        ScreenTopologyView(screens: [screen], covered: [], toggle: { _ in })
        Spacer()
    }.padding(28))
    let cover = DisplayPrivacyCoverView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
    var restored = false; cover.restore = { restored = true }
    let click = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    precondition(cover.acceptsFirstMouse(for: click), "Black cover must accept the first restoring click")
    cover.mouseDown(with: click)
    precondition(restored, "Clicking the black cover must invoke restoration")
}
let extensionMode = CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "extensions"
if extensionMode { window.contentViewController = NSHostingController(rootView: ScrollView { ExtensionSettingsView().padding(28) }) }
guard let view = window.contentView else { fatalError("Missing view") }
window.appearance = NSAppearance(named: .aqua)
window.setContentSize(NSSize(width: 980, height: 680))
window.orderFrontRegardless()
view.wantsLayer = true
view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
view.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
view.layoutSubtreeIfNeeded()
func verifyControls(_ node: NSView) {
    if let button = node as? NSButton, ["分析文件", "取消扫描", "监控目录", "停止监控", "加载更多", "复制所选", "清空历史"].contains(button.title) {
        let rect = button.convert(button.bounds, to: view)
        precondition(rect.minX >= 0 && rect.maxX <= view.bounds.width, "Control outside viewport: " + button.title)
    }
    node.subviews.forEach(verifyControls)
}
verifyControls(view)
if clipboardMode {
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(history.records.count >= 40 && history.records.count < 225 && history.totalRecordCount == 225,
                 "Clipboard UI should load enough pages for the viewport")
    func findScroll(_ node: NSView) -> NSScrollView? {
        if let scroll = node as? NSScrollView, scroll.documentView is ClipboardTagView { return scroll }
        return node.subviews.compactMap(findScroll).first
    }
    func containsPagingButton(_ node: NSView) -> Bool {
        if let button = node as? NSButton, ["重新读取", "加载更多"].contains(button.title) { return true }
        return node.subviews.contains(where: containsPagingButton)
    }
    precondition(!containsPagingButton(view), "History has no retry or paging buttons")
    guard let scroll = findScroll(view), let document = scroll.documentView else { fatalError("Missing clipboard scroll view") }
    let previouslyLoaded = history.records.count
    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentView.bounds.height)))
    scroll.reflectScrolledClipView(scroll.contentView)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(history.records.count > previouslyLoaded && history.totalRecordCount == 225,
                 "Scrolling near the bottom automatically loads the next page")
    view.layoutSubtreeIfNeeded()
    verifyControls(view)
    func findSearch(_ node: NSView) -> NSSearchField? {
        if let search = node as? NSSearchField { return search }
        return node.subviews.compactMap(findSearch).first
    }
    guard let search = findSearch(view) else { fatalError("Missing history search") }
    guard let tagView = document as? ClipboardTagView,
          let itemView = tagView.subviews.compactMap({ $0 as? ClipboardHistoryItemView }).first else {
        fatalError("Missing hoverable history item")
    }
    let entering = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 1, trackingNumber: 1, userData: nil)!
    let leaving = NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
        windowNumber: window.windowNumber, context: nil, eventNumber: 2, trackingNumber: 1, userData: nil)!
    itemView.mouseEntered(with: entering)
    precondition(!itemView.deleteButton.isHidden, "Hover reveals the delete control")
    itemView.mouseExited(with: leaving)
    precondition(itemView.deleteButton.isHidden, "Leaving hides the delete control")
    itemView.mouseEntered(with: entering)
    let itemFrames = tagView.subviews.compactMap { ($0 as? ClipboardHistoryItemView)?.frame }
    precondition(Set(itemFrames.map { "\($0.origin.x),\($0.origin.y)" }).count == itemFrames.count,
                 "History items retain distinct positions inside their hover containers")
    let deletedID = tagView.records[0].id
    let pasteboardChangeCount = uiPasteboard.changeCount
    itemView.deleteButton.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    precondition(!history.records.contains { $0.id == deletedID } && history.totalRecordCount == 224,
                 "Hover close deletes exactly one history record")
    precondition(uiPasteboard.changeCount == pasteboardChangeCount, "Deletion never copies to the clipboard")
    let afterDeletion = history.records.count
    search.stringValue = "分页测试记录 224"
    NSApp.sendAction(search.action!, to: search.target, from: search)
    RunLoop.main.run(until: Date().addingTimeInterval(0.35))
    precondition(history.searchResults.count == 1 && history.records.count == afterDeletion, "UI search must include unloaded history")
    search.stringValue = ""
    NSApp.sendAction(search.action!, to: search.target, from: search)
    view.layoutSubtreeIfNeeded()
}
if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "processes-close-confirmation" {
    func findButton(_ node: NSView, title: String) -> NSButton? {
        if let button = node as? NSButton, button.title == title { return button }
        return node.subviews.compactMap { findButton($0, title: title) }.first
    }
    func findText(_ node: NSView) -> NSTextView? {
        if let text = node as? NSTextView { return text }
        return node.subviews.compactMap(findText).first
    }
    let fixture = Process()
    fixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
    fixture.arguments = ["30"]
    try fixture.run()
    defer { if fixture.isRunning { fixture.terminate() }; fixture.waitUntilExit() }
    guard let close = findButton(view, title: "关闭非系统进程") else { fatalError("Missing renamed button") }
    close.performClick(nil)
    let deadline = Date().addingTimeInterval(8)
    while window.attachedSheet == nil && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    guard let sheet = window.attachedSheet, let sheetView = sheet.contentView,
          let list = findText(sheetView), let cancel = findButton(sheetView, title: "取消") else { fatalError("Missing confirmation and process list") }
    precondition(list.string.contains("PID \(fixture.processIdentifier)") && list.string.contains("/bin/sleep"), "Confirmation must list background commands by PID and path")
    precondition(fixture.isRunning && !close.isEnabled, "No termination before confirmation; duplicate request disabled")
    sheetView.layoutSubtreeIfNeeded()
    guard let image = sheetView.bitmapImageRepForCachingDisplay(in: sheetView.bounds) else { fatalError("Cannot render confirmation") }
    sheetView.cacheDisplay(in: sheetView.bounds, to: image)
    let confirmationURL = URL(fileURLWithPath: CommandLine.arguments[1]).deletingPathExtension().appendingPathExtension("confirmation.png")
    try image.representation(using: .png, properties: [:])!.write(to: confirmationURL)
    cancel.performClick(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    precondition(fixture.isRunning && close.isEnabled && window.attachedSheet == nil, "Cancel must leave processes running and restore the button")
    print("PASS: background command listed; confirmation closes nothing; cancel leaves fixture running")
}
precondition(!ClipboardHistory.isSharedInitialized, "UI testing must not initialize the production clipboard")
guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Cannot render window") }
view.cacheDisplay(in: view.bounds, to: bitmap)
let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let rendered = NSImage(size: view.bounds.size)
rendered.lockFocus()
window.backgroundColor.setFill(); NSRect(origin: .zero, size: view.bounds.size).fill()
bitmap.draw(in: NSRect(origin: .zero, size: view.bounds.size))
rendered.unlockFocus()
let finalBitmap = NSBitmapImageRep(data: rendered.tiffRepresentation!)!
try finalBitmap.representation(using: .png, properties: [:])!.write(to: output)
window.close()
print("Rendered \(extensionMode ? "系统扩展" : requestedModule.rawValue) page at 980x680")
