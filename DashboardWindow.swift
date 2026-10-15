import AppKit
import SwiftUI
import UserNotifications
import Carbon.HIToolbox
import ServiceManagement

private func ailockCommandTapCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent, _ refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        DashboardWindow.reEnableCommandEventTap()
        return Unmanaged.passUnretained(event)
    }
    DashboardWindow.receiveCommandEvent(type: type, event: event)
    return Unmanaged.passUnretained(event)
}

private func ailockRecorderHotkeyCallback(_ next: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotkey = EventHotKeyID()
    let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                   MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
    guard status == noErr, hotkey.signature == 0x41494C52, hotkey.id == 1 else {
        return OSStatus(eventNotHandledErr)
    }
    let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
    DispatchQueue.main.async { DashboardWindow.receiveRecorderHotkey(isPressed: pressed) }
    return noErr
}

final class DashboardWindow: NSWindowController, NSWindowDelegate {
    static var preferredColorScheme: ColorScheme? {
        switch AppSettings.shared.appearance.rawValue {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    static var preferredAppearance: NSAppearance? {
        switch AppSettings.shared.appearance.rawValue {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    enum Module: String {
        var displayTitle: String { self == .logs ? "应用日志" : rawValue }
        case menuBarOrganizer = "菜单栏收纳", files = "安全活动", processes = "进程管理", network = "网络活动", networkDiagnostics = "网络诊断", logs = "系统日志", clipboard = "剪贴板历史", settings = "监控预警", preferences = "设置", dockLock = "DockLock", search = "快速文件搜索", cacheCleaner = "系统健康检查", uninstaller = "应用卸载", launchItems = "启动项检查", launcher = "快捷操作", screenRecorder = "录屏工具", displayBrightness = "显示器控制"
    }

    static var dockLockEnabled: Bool { lockController?.enabled ?? (UserDefaults.standard.object(forKey: "dockLock.enabled") as? Bool ?? true) }
    static func toggleDockLock() -> Bool { lockController?.toggleEnabled() ?? false }
    static var dockLockTargetSetting: String { lockController?.targetSetting ?? "builtin" }
    static var dockLockScreens: [DockLock.ScreenChoice] { lockController?.screenChoices ?? [] }
    static func setDockLockTarget(_ value: String) { lockController?.setTarget(value) }
    static func clearDisplayPrivacy() { DisplayPrivacyManager.shared.clearAll() }
    static func toggleDisplayPrivacy(_ id: CGDirectDisplayID) { DisplayPrivacyManager.shared.toggle(id) }
    static var coveredDisplays: Set<CGDirectDisplayID> { DisplayPrivacyManager.shared.coveredIDs }
    private static weak var lockController: DockLock?
    private static var moduleWindows: [Module: DashboardWindow] = [:]
    private static var preferencesWindow: PreferencesWindowController?
    private static var functionalFrame: NSRect?
    static var onWillShowFunctionalWindow: (() -> Void)?

    /// Keep controllers alive so switching surfaces preserves each page's state.
    static func hideFunctionalWindows(except target: NSWindow? = nil) {
        for controller in moduleWindows.values {
            if let window = controller.window, window !== target {
                controller.suspendPageSampling()
                window.orderOut(nil)
            }
        }
        if let window = launcherWindow?.window, window !== target { window.orderOut(nil) }
        if let window = preferencesWindow?.window, window !== target {
            window.orderOut(nil)
        }
    }

    private static func presentFunctionalWindow(_ controller: NSWindowController) {
        if controller is DashboardWindow || controller is PreferencesWindowController {
            let visible = moduleWindows.values.compactMap(\.window).first { $0.isVisible && $0 !== controller.window }
                ?? preferencesWindow?.window.flatMap { $0.isVisible && $0 !== controller.window ? $0 : nil }
            if let visible { functionalFrame = visible.frame }
            if let frame = functionalFrame { controller.window?.setFrame(frame, display: true) }
        }
        controller.window?.appearance = preferredAppearance
        onWillShowFunctionalWindow?()
        hideFunctionalWindows(except: controller.window)
        if controller.window?.isMiniaturized == true {
            controller.window?.deminiaturize(nil)
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        if controller is DashboardWindow || controller is PreferencesWindowController {
            functionalFrame = controller.window?.frame
        }
        (controller as? DashboardWindow)?.resumePageSampling()
        NSApp.activate(ignoringOtherApps: true)
    }
    private var moduleRoot: NSView?
    private var moduleHostingViews: [Module: NSHostingView<LumenModuleContent>] = [:]
    /// Edge constraints per cached page; only the visible page's constraints are active.
    private var moduleConstraints: [Module: [NSLayoutConstraint]] = [:]

    init(module: Module? = nil, window suppliedWindow: NSWindow? = nil, registerServices: Bool = true, clipboardHistory suppliedClipboardHistory: ClipboardHistory? = nil) {
        injectedClipboardHistory = suppliedClipboardHistory
        let size: NSSize = module.map { LumenWindowMetrics.size(for: $0) } ?? NSSize(width: 1120, height: 700)
        let window = suppliedWindow ?? NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.text(module == .logs ? L10n.text("AI Lock 应用日志") : (module?.rawValue ?? "AI Lock"))
        window.minSize = module.map { LumenWindowMetrics.minimumSize(for: $0) } ?? NSSize(width: 960, height: 620)
        window.backgroundColor = canvas
        window.appearance = Self.preferredAppearance
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: L10n.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance),
                                              name: .appearanceModeChanged, object: nil)
        window.delegate = self
        self.module = module
        if let module { buildModuleWindow(module) }
        if registerServices { initializeExtraServices() }
        if module == .clipboard {
            clipboardHistory.start()
        }
    }

    private var processesModule: ProcessesModuleController?
    private var networkDiagnosticsModel: NetworkDiagnosticsModel?
    /// 网络诊断的控制台由 SwiftUI 持有模型，这里留存引用以便挂起窗口时取消任务。
    static func registerDiagnosticsModel(_ model: NetworkDiagnosticsModel) {
        for controller in moduleWindows.values where controller.module == .networkDiagnostics {
            controller.networkDiagnosticsModel = model
        }
    }








    private func suspendPageSampling() {
        networkDiagnosticsModel?.cancel()
        processesModule?.stop()
        fileSearch.cancel()
        // 页面窗口只是隐藏而非销毁，SwiftUI 的 onDisappear 不会触发，
        // 因此显式通知当前页面的模型停止后台采样。
        if let module {
            NotificationCenter.default.post(name: .lumenModuleDidSuspend, object: module.rawValue)
        }
    }
    private func resumePageSampling() {
        guard let module else { return }
        NotificationCenter.default.post(name: .lumenModuleDidResume, object: module.rawValue)
    }

    func windowDidMove(_ notification: Notification) { rememberFrame() }
    func windowDidResize(_ notification: Notification) { rememberFrame() }
    private func rememberFrame() {
        if let window, window.isVisible { Self.functionalFrame = window.frame }
    }
    func windowWillClose(_ notification: Notification) { rememberFrame(); suspendPageSampling() }
    @objc private func refreshLanguage() {
        guard let window else { return }
        NativeLocalization.refresh(window)
        window.title = L10n.text(module == .logs ? "AI Lock 应用日志" : module?.rawValue ?? "AI Lock")
        if module == .clipboard { clipboardModule?.refreshStatusText() }
    }

    @objc private func refreshAppearance() {
        window?.appearance = Self.preferredAppearance
        if module == .networkDiagnostics { window?.backgroundColor = DiagnosticConsole.backgroundColor }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    func windowDidMiniaturize(_ notification: Notification) { suspendPageSampling() }
    func windowDidDeminiaturize(_ notification: Notification) { resumePageSampling() }

    private var module: Module?

    private func buildModuleWindow(_ module: Module) {
        guard let window else { return }
        // 统一由 LumenModuleContent 渲染：左侧导航 + 右侧数据面。
        // 侧栏切换模块时走 open(_:)，保持「一个模块一个窗口、切换时挂起采样」的既有行为。
        let container = NSView(frame: NSRect(origin: .zero, size: window.contentView?.bounds.size ?? window.frame.size))
        container.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = container
        moduleRoot = container
        activeModuleWindow = window
        installModuleContent(module, in: container)
        window.center()
    }

    private func installModuleContent(_ module: Module, in container: NSView) {
        // Pages stay attached and are only hidden or shown. Detaching and re-attaching a hosting view
        // re-renders the whole page from blank on every sidebar click, which reads as the window
        // closing and reopening. Hidden pages are paused through the suspend/resume notifications,
        // and their edge constraints are released so resizing does not lay out pages nobody can see.
        if moduleHostingViews[module] == nil {
            let root = LumenModuleContent(module: module, clipboardHistory: clipboardHistory) { [weak self] next in
                guard next != self?.module else { return }
                _ = Self.open(next)
            }
            let hosting = NSHostingView(rootView: root)
            // The shared shell owns window geometry; page ideal sizes must not resize it.
            hosting.sizingOptions = []
            hosting.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(hosting)
            moduleConstraints[module] = [
                hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: container.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ]
            moduleHostingViews[module] = hosting
        }
        for (key, hosting) in moduleHostingViews where key != module {
            hosting.isHidden = true
            NSLayoutConstraint.deactivate(moduleConstraints[key] ?? [])
        }
        if let hosting = moduleHostingViews[module] {
            hosting.isHidden = false
            NSLayoutConstraint.activate(moduleConstraints[module] ?? [])
        }
    }

    private func switchModule(to next: Module) {
        guard next != module, let window, let moduleRoot else { return }
        suspendPageSampling()
        // Drop focus from the page being hidden so keystrokes don't land in an invisible view.
        window.makeFirstResponder(nil)
        module = next
        window.title = L10n.text(next == .logs ? "AI Lock 应用日志" : next.rawValue)
        window.backgroundColor = next == .networkDiagnostics ? DiagnosticConsole.backgroundColor : canvas
        installModuleContent(next, in: moduleRoot)
        if next == .clipboard { clipboardHistory.start() }
    }

    static func open(_ module: Module) -> DashboardWindow {
        let controller = moduleWindows.values.first ?? DashboardWindow(module: module)
        if controller.module != module {
            controller.switchModule(to: module)
            moduleWindows = [module: controller]
        } else if moduleWindows[module] == nil {
            moduleWindows[module] = controller
        }
        presentFunctionalWindow(controller)
        return controller
    }

    static func openPreferences(section: String? = nil) {
        if let section { UserDefaults.standard.set(section, forKey: "preferences.selectedSection") }
        let controller = preferencesWindow ?? PreferencesWindowController()
        preferencesWindow = controller
        presentFunctionalWindow(controller)
    }

    static func openCommandPalette() {
        _ = open(.search)
    }

    static func openLauncher() {
        let controller = launcherWindow ?? QuickActionWindowController()
        launcherWindow = controller
        if controller.window?.isVisible == true {
            controller.window?.orderOut(nil)
            return
        }
        controller.prepare()
        presentFunctionalWindow(controller)
        controller.focusSearch()
    }

    static func setDockLockController(_ controller: DockLock) { lockController = controller }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private let injectedClipboardHistory: ClipboardHistory?
    private lazy var clipboardHistory = injectedClipboardHistory ?? ClipboardHistory.shared
    private let fileSearch = QuickSearch.shared
    private var clipboardModule: ClipboardModuleController?
    private weak var activeModuleWindow: NSWindow?
    private static var commandDetector = CommandDoubleTapDetector()
    private static var launcherWindow: QuickActionWindowController?
    private static var recorderHotkey: EventHotKeyRef?
    private static var recorderHotkeyHandler: EventHandlerRef?
    private static var recorderHotkeyHeld = false
    private static let recorderDefaultModifiers = 1 | 4 | 8 // Command + Control + Shift
    private static var commandEventTap: CFMachPort?
    private static var commandEventTapSource: CFRunLoopSource?
    private static var commandLocalMonitor: Any?
    private static var commandRetryTimer: Timer?
    private static let quickActionShortcutEnabledKey = "quickAction.shortcut.customEnabled"
    private static let quickActionShortcutKeyCodeKey = "quickAction.shortcut.keyCode"
    private static let screenRecorderShortcutKeyCodeKey = "screenRecorder.shortcut.keyCode"
    private static let screenRecorderShortcutModifiersKey = "screenRecorder.shortcut.modifiers"
    private static let screenRecorderShortcutEnabledKey = "screenRecorder.shortcut.enabled"
    private static let quickActionShortcutModifiersKey = "quickAction.shortcut.modifiers"
    private static let commandInputMonitoringError = "双击 Command 未启用：需要输入监控权限，请在快捷键设置中开启。"

    static var quickActionShortcutTitle: String {
        guard UserDefaults.standard.bool(forKey: quickActionShortcutEnabledKey) else { return "⌘ 两次" }
        let modifiers = UserDefaults.standard.integer(forKey: quickActionShortcutModifiersKey)
        let keyCode = UInt16(clamping: UserDefaults.standard.integer(forKey: quickActionShortcutKeyCodeKey))
        return shortcutModifierTitle(modifiers) + shortcutKeyTitle(keyCode: keyCode, fallback: "?")
    }

    static var screenRecorderShortcutTitle: String {
        let defaults = UserDefaults.standard
        let modifiers = defaults.object(forKey: screenRecorderShortcutModifiersKey) == nil
            ? recorderDefaultModifiers
            : defaults.integer(forKey: screenRecorderShortcutModifiersKey)
        let keyCode = defaults.object(forKey: screenRecorderShortcutKeyCodeKey) == nil
            ? Int(kVK_ANSI_R)
            : defaults.integer(forKey: screenRecorderShortcutKeyCodeKey)
        return shortcutModifierTitle(modifiers) + shortcutKeyTitle(keyCode: UInt16(clamping: keyCode), fallback: "R")
    }

    static func saveScreenRecorderShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        var mask = 0
        if flags.contains(.command) { mask |= 1 }
        if flags.contains(.option) { mask |= 2 }
        if flags.contains(.control) { mask |= 4 }
        if flags.contains(.shift) { mask |= 8 }
        UserDefaults.standard.set(Int(keyCode), forKey: screenRecorderShortcutKeyCodeKey)
        UserDefaults.standard.set(mask, forKey: screenRecorderShortcutModifiersKey)
        UserDefaults.standard.set(true, forKey: screenRecorderShortcutEnabledKey)
    }

    static func resetScreenRecorderShortcut() {
        UserDefaults.standard.removeObject(forKey: screenRecorderShortcutEnabledKey)
        UserDefaults.standard.removeObject(forKey: screenRecorderShortcutKeyCodeKey)
        UserDefaults.standard.removeObject(forKey: screenRecorderShortcutModifiersKey)
        _ = refreshGlobalHotkeys()
    }

    static var hasCustomQuickActionShortcut: Bool {
        UserDefaults.standard.bool(forKey: quickActionShortcutEnabledKey)
    }

    static func saveQuickActionShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        var mask = 0
        if flags.contains(.command) { mask |= 1 }
        if flags.contains(.option) { mask |= 2 }
        if flags.contains(.control) { mask |= 4 }
        if flags.contains(.shift) { mask |= 8 }
        UserDefaults.standard.set(Int(keyCode), forKey: quickActionShortcutKeyCodeKey)
        UserDefaults.standard.set(mask, forKey: quickActionShortcutModifiersKey)
        UserDefaults.standard.set(true, forKey: quickActionShortcutEnabledKey)
        commandDetector.reset()
    }

    static func resetQuickActionShortcut() {
        UserDefaults.standard.removeObject(forKey: quickActionShortcutEnabledKey)
        UserDefaults.standard.removeObject(forKey: quickActionShortcutKeyCodeKey)
        UserDefaults.standard.removeObject(forKey: quickActionShortcutModifiersKey)
        commandDetector.reset()
    }

    private static func shortcutModifierTitle(_ modifiers: Int) -> String {
        var title = ""
        if modifiers & 4 != 0 { title += "⌃" }
        if modifiers & 2 != 0 { title += "⌥" }
        if modifiers & 8 != 0 { title += "⇧" }
        if modifiers & 1 != 0 { title += "⌘" }
        return title
    }

    private static func shortcutKeyTitle(keyCode: UInt16, fallback: String) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "空格"
        case kVK_Return, kVK_ANSI_KeypadEnter: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_Escape: return "Esc"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        default:
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
            let layout = unsafeBitCast(raw, to: CFData.self)
            guard let bytes = CFDataGetBytePtr(layout) else { return fallback }
            var deadKeyState: UInt32 = 0
            var length = 0
            var characters = [UniChar](repeating: 0, count: 8)
            let status = UCKeyTranslate(UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self),
                UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, characters.count,
                &length, &characters)
            guard status == noErr, length > 0 else { return fallback }
            return String(utf16CodeUnits: characters, count: length).uppercased()
        }
    }

    private static func eventModifierMask(_ flags: CGEventFlags) -> Int {
        var mask = 0
        if flags.contains(.maskCommand) { mask |= 1 }
        if flags.contains(.maskAlternate) { mask |= 2 }
        if flags.contains(.maskControl) { mask |= 4 }
        if flags.contains(.maskShift) { mask |= 8 }
        return mask
    }

    private static func eventModifierMask(_ flags: NSEvent.ModifierFlags) -> Int {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var mask = 0
        if flags.contains(.command) { mask |= 1 }
        if flags.contains(.option) { mask |= 2 }
        if flags.contains(.control) { mask |= 4 }
        if flags.contains(.shift) { mask |= 8 }
        return mask
    }

    private static func matchesQuickActionShortcut(keyCode: Int64, modifiers: Int) -> Bool {
        guard hasCustomQuickActionShortcut else { return false }
        return keyCode == Int64(UserDefaults.standard.integer(forKey: quickActionShortcutKeyCodeKey))
            && modifiers == UserDefaults.standard.integer(forKey: quickActionShortcutModifiersKey)
    }

    static func receiveRecorderHotkey(isPressed: Bool) {
        guard isPressed else { recorderHotkeyHeld = false; return }
        guard !recorderHotkeyHeld else { return }
        recorderHotkeyHeld = true
        commandDetector.reset()
        ScreenRecorderModel.shared.toggleRecording()
    }

    private static func registerRecorderHotkey() {
        if let recorderHotkey { UnregisterEventHotKey(recorderHotkey) }
        recorderHotkey = nil
        recorderHotkeyHeld = false
        if recorderHotkeyHandler == nil {
            var events = [
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
            ]
            let status = InstallEventHandler(GetApplicationEventTarget(), ailockRecorderHotkeyCallback,
                                            events.count, &events, nil, &recorderHotkeyHandler)
            guard status == noErr else {
                hotkeyRegistrationErrors.append(L10n.text("录屏快捷键监听注册失败。"))
                return
            }
        }
        let defaults = UserDefaults.standard
        let keyCode = defaults.object(forKey: screenRecorderShortcutKeyCodeKey) == nil
            ? Int(kVK_ANSI_R) : defaults.integer(forKey: screenRecorderShortcutKeyCodeKey)
        let mask = defaults.object(forKey: screenRecorderShortcutModifiersKey) == nil
            ? recorderDefaultModifiers : defaults.integer(forKey: screenRecorderShortcutModifiersKey)
        var modifiers: UInt32 = 0
        if mask & 1 != 0 { modifiers |= UInt32(cmdKey) }
        if mask & 2 != 0 { modifiers |= UInt32(optionKey) }
        if mask & 4 != 0 { modifiers |= UInt32(controlKey) }
        if mask & 8 != 0 { modifiers |= UInt32(shiftKey) }
        let status = RegisterEventHotKey(UInt32(clamping: keyCode), modifiers,
            EventHotKeyID(signature: 0x41494C52, id: 1), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &recorderHotkey)
        if status != noErr {
            hotkeyRegistrationErrors.append(L10n.text("录屏快捷键已被占用，请在设置中更换组合。"))
        }
    }

    private static func triggerCustomQuickActionShortcut() {
        commandDetector.reset()
        openLauncher()
    }

    @discardableResult static func refreshGlobalHotkeys() -> [String] {
        hotkeyRegistrationErrors.removeAll()
        registerRecorderHotkey()
        installCommandEventTap()
        hotkeyRegistrationErrors.forEach { log($0) }
        return hotkeyRegistrationErrors
    }

    private func initializeExtraServices() {
        _ = Self.refreshGlobalHotkeys()
    }

    private static var hotkeyRegistrationErrors: [String] = []

    private static func installCommandEventTap() {
        // The event tap sees keys for every other app; the local monitor sees keys only while AI Lock is
        // active. The two are split by activation, so each key press reaches the handlers exactly once.
        if commandLocalMonitor == nil {
            commandLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
                guard NSApp.isActive else { return event }
                let isKeyDown = event.type == .keyDown
                let isCommandKey = event.keyCode == UInt16(kVK_Command) || event.keyCode == UInt16(kVK_RightCommand)
                let otherFlags: NSEvent.ModifierFlags = [.shift, .control, .option]
                handleInputEvent(isKeyDown: isKeyDown,
                                 keyCode: Int64(event.keyCode),
                                 modifiers: eventModifierMask(event.modifierFlags),
                                 isRepeat: event.isARepeat,
                                 isCommandKey: isCommandKey,
                                 commandDown: event.modifierFlags.contains(.command),
                                 otherKey: isKeyDown || !isCommandKey || !event.modifierFlags.intersection(otherFlags).isEmpty,
                                 timestamp: event.timestamp)
                return event
            }
        }
        guard commandEventTap == nil else { return }
        guard CGPreflightListenEventAccess() else {
            requestInputMonitoringOnce()
            if !hotkeyRegistrationErrors.contains(commandInputMonitoringError) {
                hotkeyRegistrationErrors.append(commandInputMonitoringError)
                log(commandInputMonitoringError)
            }
            if commandRetryTimer == nil {
                commandRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in installCommandEventTap() }
            }
            return
        }
        let mask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        commandEventTap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
            options: .listenOnly, eventsOfInterest: mask, callback: ailockCommandTapCallback, userInfo: nil)
        guard let commandEventTap else {
            if !hotkeyRegistrationErrors.contains(commandInputMonitoringError) {
                hotkeyRegistrationErrors.append(commandInputMonitoringError)
                log(commandInputMonitoringError)
            }
            if commandRetryTimer == nil {
                commandRetryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { _ in installCommandEventTap() }
            }
            return
        }
        hotkeyRegistrationErrors.removeAll { $0.hasPrefix("双击 Command 未启用") }
        commandRetryTimer?.invalidate()
        commandRetryTimer = nil
        commandDetector.reset()
        commandEventTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, commandEventTap, 0)
        if let commandEventTapSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), commandEventTapSource, .commonModes)
            CGEvent.tapEnable(tap: commandEventTap, enable: true)
            log("Command 全局监听已启动：输入监控=\(CGPreflightListenEventAccess())，辅助功能=\(AXIsProcessTrusted())")
        }
    }

    fileprivate static func reEnableCommandEventTap() {
        commandDetector.reset()
        if let commandEventTap { CGEvent.tapEnable(tap: commandEventTap, enable: true) }
    }

    /// Set once per launch so the Input Monitoring prompt is not requested again on every retry.
    private static var inputMonitoringRequested = false

    /// Asks macOS for Input Monitoring the first time it is missing. The system shows its prompt only
    /// while the decision is undetermined, so an earlier denial never produces repeated prompts.
    private static func requestInputMonitoringOnce() {
        guard !inputMonitoringRequested else { return }
        inputMonitoringRequested = true
        _ = CGRequestListenEventAccess()
    }

    /// Adds AI Lock to the Input Monitoring list and opens that page of System Settings.
    static func requestInputMonitoringAccess() {
        _ = CGRequestListenEventAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    static var hasInputMonitoringAccess: Bool { CGPreflightListenEventAccess() }

    /// True once the global event tap is running, i.e. shortcuts also work while other apps are active.
    static var globalShortcutsActive: Bool { commandEventTap != nil }

    private static func handleInputEvent(isKeyDown: Bool, keyCode: Int64, modifiers: Int, isRepeat: Bool,
                                         isCommandKey: Bool, commandDown: Bool, otherKey: Bool, timestamp: TimeInterval) {
        if isKeyDown, keyCode == Int64(kVK_Escape) {
            DisplayPrivacyManager.shared.cancelBlackoutTest()
            return
        }
        if isKeyDown, !isRepeat, matchesQuickActionShortcut(keyCode: keyCode, modifiers: modifiers) {
            triggerCustomQuickActionShortcut()
            return
        }
        guard !hasCustomQuickActionShortcut else {
            commandDetector.reset()
            return
        }
        if isCommandKey, !isKeyDown, CommandLine.arguments.contains("--diagnose-hotkeys") {
            log("Command 手势：\(commandDown ? "按下" : "松开")，附加修饰键=\(otherKey)，事件时间=\(timestamp)")
        }
        handleCommandDoubleTap(commandDown: commandDown, otherKey: otherKey, timestamp: timestamp)
    }

    static func receiveCommandEvent(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged || type == .keyDown else { return }
        // Read everything from the event now; the tap's event object is only reliable inside the callback.
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let isKeyDown = type == .keyDown
        let isCommandKey = keyCode == Int64(kVK_Command) || keyCode == Int64(kVK_RightCommand)
        let otherFlags: CGEventFlags = [.maskShift, .maskControl, .maskAlternate]
        let otherKey = isKeyDown || !event.flags.intersection(otherFlags).isEmpty || !isCommandKey
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let modifiers = eventModifierMask(event.flags)
        let commandDown = event.flags.contains(.maskCommand)
        let timestamp = Double(event.timestamp) / 1_000_000_000
        DispatchQueue.main.async {
            // While AI Lock is active, the local monitor has already seen this event.
            guard !NSApp.isActive else { return }
            handleInputEvent(isKeyDown: isKeyDown, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat,
                             isCommandKey: isCommandKey, commandDown: commandDown, otherKey: otherKey, timestamp: timestamp)
        }
    }

    fileprivate static func handleCommandDoubleTap(commandDown: Bool, otherKey: Bool, timestamp: TimeInterval) {
        if commandDetector.update(commandDown: commandDown, otherKey: otherKey, timestamp: timestamp) {
            log("Command 双击已识别，打开快捷操作条")
            openLauncher()
        }
    }

















































































    private weak var launchItemsStatus: NSTextField?
    @objc private func refreshLaunchItems(_ sender: Any?) {
        launchItemsStatus?.stringValue = L10n.text("正在读取 plist…")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let items = StartupItemInspector.scan()
            DispatchQueue.main.async {
                self?.launchItemsStatus?.stringValue = L10n.format("发现 %{0} 个配置项目（含异常项）", arguments: [String(describing: items.count)])
            }
        }
    }







    /// Finder can request administrator authorization when the current process
    /// cannot move a LaunchAgent plist to the user's Trash itself.
    /// 移入废纸篓失败（通常因权限不足）时改由 Finder 处理，让系统弹出授权。
    /// 由启动项页面调用，因此不设为 private。
    static func deleteStartupItemWithFinder(_ url: URL) -> Error? {
        let escapedPath = url.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = NSAppleScript(source: "tell application \"Finder\" to delete POSIX file \"\(escapedPath)\"")
        guard let script else {
            return NSError(domain: "StartupItemDeletion", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "无法请求 Finder 删除此启动项。请在 Finder 中手动移入废纸篓，并按提示授权。"])
        }
        var scriptError: NSDictionary?
        _ = script.executeAndReturnError(&scriptError)
        if scriptError == nil { return nil }
        guard let scriptError else {
            return NSError(domain: "StartupItemDeletion", code: 1,
                           userInfo: [NSLocalizedDescriptionKey: "Finder 未能完成删除。请在 Finder 中手动移入废纸篓，并按提示授权。"])
        }
        let message = scriptError[NSAppleScript.errorMessage] as? String ?? "Finder 无法删除此启动项。请在 Finder 中手动移入废纸篓，并按提示授权。"
        return NSError(domain: "StartupItemDeletion", code: scriptError[NSAppleScript.errorNumber] as? Int ?? 1,
                       userInfo: [NSLocalizedDescriptionKey: message])
    }



















    @objc fileprivate func toggleDisplayPrivacy(_ sender: NSButton) {
        DisplayPrivacyManager.shared.toggle(CGDirectDisplayID(sender.tag))
    }








    @objc private func sendTestNotification(_ sender: Any?) {
        NotificationCenter.default.post(name: .resourceAlertPreview, object: nil)
    }







}

struct DashboardOverviewView: View {
    @AppStorage("appearance.mode") private var homeAppearance = "system"
    @Environment(\.colorScheme) private var homeColorScheme
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @ObservedObject private var menuBarOrganizer = MenuBarOrganizer.shared
    @ObservedObject private var monitoring = MonitoringService.shared
    private var snapshot: SystemSnapshot { monitoring.snapshot }
    private var history: [NetworkHistoryPoint] { NetworkHistory.shared.snapshot(now: snapshot.timestamp) }
    @State private var query = ""
    @State private var searchResults: [SearchResult] = []
    @State private var searchNeedsDiskAccess = false
    @State private var editingShortcuts = false
    @State private var showingPreferences = false
    @State private var showingHotkeySettings = false
    @State private var draggingModule: String?
    @State private var shortcutPressID: UUID?
    @AppStorage("overview.language") private var selectedEnglish = false
    @AppStorage("overview.followSystemLanguage") private var followSystemLanguage = true
    private var english: Bool { L10n.isEnglish }
    private var languageSelection: Binding<String> {
        Binding(get: { followSystemLanguage ? "system" : (selectedEnglish ? "en" : "zh") }, set: { value in
            followSystemLanguage = value == "system"
            if value != "system" { selectedEnglish = value == "en" }
            NotificationCenter.default.post(name: L10n.changed, object: nil)
        })
    }
    @AppStorage("overview.fontScale.v1") private var fontSize = 1.0
    @AppStorage("overview.statusMetrics") private var statusMetricsRaw = ""
    @AppStorage("overview.networkDiagnosticsAdded.v1") private var diagnosticsAdded = false
    @AppStorage("overview.screenRecorderAdded.v1") private var screenRecorderAdded = false
    @AppStorage("overview.visibleModules.v1") private var stableVisibleModulesRaw = ""
    private var visibleModulesRaw: String {
        get { AppSettings.moduleTitleCSV(stableVisibleModulesRaw) }
        nonmutating set { guard AppSettings.shared.supportsWrites else { return }; let stable = AppSettings.stableModuleCSV(newValue); stableVisibleModulesRaw = stable.isEmpty ? "__none__" : stable }
    }
    @AppStorage("overview.moduleOrder.v1") private var stableModuleOrderRaw = ""
    private var moduleOrderRaw: String {
        get { AppSettings.moduleTitleCSV(stableModuleOrderRaw) }
        nonmutating set { guard AppSettings.shared.supportsWrites else { return }; stableModuleOrderRaw = AppSettings.stableModuleCSV(newValue) }
    }
    @State private var showingHelp = false
    @State private var dockLockEnabled = DashboardWindow.dockLockEnabled
    @State private var dockLockTarget = DashboardWindow.dockLockTargetSetting
    @State private var edgeMargin = AppSettings.shared.edgeMargin
    @State private var autoSnap = AppSettings.shared.autoSnap
    @State private var cpuAlertThreshold = AppSettings.shared.alerts.cpu
    @State private var memoryAlertThreshold = AppSettings.shared.alerts.memory
    @State private var diskAlertThreshold = AppSettings.shared.alerts.diskFreePercent
    @State private var networkAlertThreshold = AppSettings.shared.alerts.networkMB
    @State private var batteryAlertThreshold = AppSettings.shared.alerts.batteryPercent
    @State private var thermalAlertThreshold = AppSettings.shared.alerts.thermalLevel
    private var statusMetrics: Set<String> {
        get { Set(statusMetricsRaw.split(separator: ",").map(String.init)) }
        nonmutating set { statusMetricsRaw = newValue.sorted().joined(separator: ",") }
    }
    @State private var search = QuickSearch.shared
    private let alerts = ResourceAlerts()
    private var uiScale: CGFloat { CGFloat(fontSize > 3 ? fontSize / 13 : fontSize) }
    private var scaledFontSize: CGFloat { 13 * uiScale }
    private func industrialTint(_ module: String) -> Color {
        switch module {
        case "network", "files", "launchItems": return Color(red: 0.19, green: 0.47, blue: 0.64)
        case "clipboard", "dockLock", "systemHealth": return Color(red: 0.20, green: 0.53, blue: 0.49)
        case "processes", "logs", "uninstaller": return Color(red: 0.65, green: 0.43, blue: 0.25)
        default: return Color(red: 0.42, green: 0.48, blue: 0.56)
        }
    }


    private let modules: [(String, String, DashboardWindow.Module)] = [
        ("系统健康检查", "stethoscope", .cacheCleaner),
        ("DockLock", "dock.rectangle", .dockLock),
        ("菜单栏收纳", "menubar.rectangle", .menuBarOrganizer),
        ("安全活动", "shield.lefthalf.filled", .files),
        ("应用卸载", "app.dashed", .uninstaller),
        ("启动项检查", "rectangle.stack.badge.play", .launchItems),
        ("进程管理", "cpu", .processes),
        ("网络活动", "network", .network),
        ("网络诊断", "speedometer", .networkDiagnostics),
        ("显示器控制", "sun.max", .displayBrightness),
        ("录屏工具", "record.circle", .screenRecorder),
        ("应用日志", "list.bullet.rectangle", .logs),
        ("剪贴板历史", "clipboard", .clipboard),
    ]

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField(L10n.text(english ? "Press ⌘ twice to open Quick Search" : L10n.text("按 ⌘ 两次打开快捷搜索")), text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 10)
                    .frame(height: 32)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                    .focusable(false)
                    .onChange(of: query) { _, value in
                        search.search(value) { results in
                            searchResults = results
                            searchNeedsDiskAccess = search.requiresFullDiskAccess
                        }
                    }
                    .onSubmit(runSearch)
                Button(action: runSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 32, height: 32)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.25)))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                }
                    .buttonStyle(.plain)
                    .delayedHelp(L10n.text(english ? "Open the first matching app or file." : L10n.text("搜索应用或文件，打开首个匹配结果。")))
                Button { languageSelection.wrappedValue = english ? "zh" : "en" } label: {
                    Text(english ? "中" : "EN")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 32, height: 32)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(english ? "Switch to Chinese" : "切换为英文")
                .accessibilityLabel(english ? "Switch to Chinese" : "切换为英文")
                Button { homeAppearance = homeColorScheme == .dark ? "light" : "dark" } label: {
                    Image(systemName: homeColorScheme == .dark ? "sun.max" : "moon")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 32, height: 32)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(english ? (homeColorScheme == .dark ? "Switch to light appearance" : "Switch to dark appearance") : (homeColorScheme == .dark ? "切换为浅色样式" : "切换为深色样式"))
                .accessibilityLabel(english ? "Toggle appearance" : "切换深浅样式")
                Button { DashboardWindow.openPreferences() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .regular))
                        .frame(width: 32, height: 32)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                }
                .buttonStyle(.plain)
                .help(L10n.text("设置"))
                .accessibilityLabel(L10n.text("设置"))
            }

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    if searchNeedsDiskAccess {
                        Button(action: SearchDiskAccess.openSettings) {
                            Label(L10n.text("当前程序的文件访问被系统拦截"), systemImage: "externaldrive")
                                .font(.system(size: scaledFontSize - 1))
                        }.buttonStyle(.plain)
                    }
                    ForEach(searchResults.prefix(5)) { result in
                        Button {
                            search.open(result)
                            search.cancel()
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: result.icon)
                                    .resizable().scaledToFit().frame(width: 22, height: 22)
                                Text(L10n.text(result.title)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(L10n.text(english ? (result.kind == .application ? "App" : result.kind == .directory ? "Folder" : "File") : result.typeLabel))
                                    .foregroundStyle(.tertiary)
                            }
                            .font(.system(size: scaledFontSize - 1))
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
            }

            HStack(spacing: 10) {
                metric("CPU", symbol: "cpu", value: String(format: "%.0f%%", snapshot.cpuUsage * 100), isAlert: snapshot.cpuUsage * 100 >= alerts.threshold(for: .cpu))
                metric("内存", symbol: "memorychip", value: percent(snapshot.memoryUsed, snapshot.memoryTotal), isAlert: snapshot.memoryPressure == "偏高" || snapshot.memoryPressure == "严重" || (snapshot.memoryTotal > 0 && Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) * 100 >= alerts.threshold(for: .memory)))
                metric("硬盘", symbol: "internaldrive", value: percent(snapshot.diskUsed, snapshot.diskTotal), isAlert: diskIsLow)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.text(english ? "Network Usage" : L10n.text("网络用量")))
                        .font(.system(size: scaledFontSize - 2, weight: .regular))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("↓ \(rate(snapshot.networkDownload))  ↑ \(rate(snapshot.networkUpload))")
                        .font(.system(size: scaledFontSize - 2, design: .monospaced))
                }
                NetworkSparkline(samples: history)
                    .frame(height: 76)
            }
            .padding(9)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 10))

            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4), spacing: 12) {
                ForEach(orderedVisibleModules, id: \.0) { title, symbol, module in
                    Button {
                        if editingShortcuts {
                            return
                        } else if module == .menuBarOrganizer {
                            menuBarOrganizer.toggleEnabled()
                        } else if module == .dockLock {
                            dockLockEnabled = DashboardWindow.toggleDockLock()
                        } else if module == .preferences {
                            DashboardWindow.openPreferences()
                        } else { _ = DashboardWindow.open(module) }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            IndustrialShortcutFace(
                                title: L10n.text(localized(title)), symbol: symbol,
                                tint: industrialTint(module.rawValue), scale: uiScale,
                                dockEnabled: module == .dockLock ? dockLockEnabled : (module == .menuBarOrganizer ? menuBarOrganizer.enabled : nil)
                            )
                            if editingShortcuts {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: scaledFontSize))
                                    .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .delayedHelp(module == .menuBarOrganizer
                          ? (menuBarOrganizer.enabled ? "菜单栏收纳已开启，点击关闭。" : "点击开启菜单栏收纳。")
                          : module == .dockLock
                          ? (dockLockEnabled ? (english ? "DockLock is on. Click to turn off." : "DockLock 已开启，点击关闭。") : (english ? "DockLock is off. Click to turn on." : "DockLock 已关闭，点击开启。"))
                          : description(for: module, title: L10n.text(title)))
                    .accessibilityValue(module == .menuBarOrganizer ? (menuBarOrganizer.enabled ? "已开启" : "已关闭") : module == .dockLock ? (dockLockEnabled ? (english ? "On" : "已开启") : (english ? "Off" : "已关闭")) : "")
                    .onLongPressGesture(minimumDuration: 2, pressing: { isPressing in
                        if isPressing {
                            let pressID = UUID()
                            shortcutPressID = pressID
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                guard shortcutPressID == pressID else { return }
                                editingShortcuts = true
                            }
                        } else {
                            shortcutPressID = nil
                        }
                    }, perform: {})
                    .onDrag {
                        guard editingShortcuts else { return NSItemProvider() }
                        draggingModule = module.rawValue
                        return NSItemProvider(object: module.rawValue as NSString)
                    }
                    .onDrop(of: [.text], delegate: ShortcutReorderDelegate(module: module.rawValue, order: orderedVisibleModules.map(\.2.rawValue), dragging: $draggingModule, update: reorderModules))
                    .contextMenu {
                        if editingShortcuts {
                            Button(L10n.text(english ? "Remove from Home" : L10n.text("从首页移除")), systemImage: "minus.circle") { hideModule(module) }
                            Button(L10n.text(english ? "Finish Editing" : L10n.text("完成编辑")), systemImage: "checkmark") { editingShortcuts = false }
                        }
                    }
                }
            }

            if editingShortcuts {
                HStack {
                    Text(L10n.text(english ? "Drag icons to reorder or remove them." : L10n.text("拖动图标可调整顺序，右键可移除。")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text(english ? "Done" : L10n.text("完成"))) { editingShortcuts = false }
                        .keyboardShortcut(.defaultAction)
                }
            }

        }
        .padding(16)
        .frame(width: 390)
        .background {
            Color(nsColor: .windowBackgroundColor)
            IndustrialGrid().stroke(Color.primary.opacity(0.055), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
        .environment(\.font, .system(size: scaledFontSize))
        .preferredColorScheme(homeAppearance == "light" ? .light : homeAppearance == "dark" ? .dark : nil)
        .onChange(of: homeAppearance) { _, _ in
            NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
        }
        .sheet(isPresented: $showingPreferences) {
            VStack(alignment: .leading, spacing: 16) {
                Picker(L10n.text(english ? "Language" : L10n.text("语言")), selection: languageSelection) {
                    Text(L10n.text("中文")).tag("zh")
                    Text("English").tag("en")
                    Text(L10n.text(english ? "Follow System" : L10n.text("跟随系统"))).tag("system")
                }
                Picker(L10n.text(english ? "Text Size" : L10n.text("文字大小")), selection: $fontSize) {
                    Text(L10n.text(english ? "Small" : L10n.text("小"))).tag(0.9)
                    Text(L10n.text(english ? "Default" : L10n.text("中"))).tag(1.0)
                    Text(L10n.text(english ? "Large" : L10n.text("大"))).tag(1.15)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(english ? "Menu Bar Metrics" : L10n.text("顶部图标后显示")))
                    Toggle("CPU", isOn: metricBinding("cpu"))
                    Toggle(L10n.text(english ? "Memory" : L10n.text("内存")), isOn: metricBinding("memory"))
                    Toggle(L10n.text(english ? "Disk" : L10n.text("硬盘")), isOn: metricBinding("disk"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(english ? "Resource Alerts" : L10n.text("监控预警")))
                    thresholdRow(english ? "CPU threshold" : "CPU 预警阈值", unit: "%", value: $cpuAlertThreshold)
                    thresholdRow(english ? "Memory usage threshold" : "内存使用量预警阈值", unit: "%", value: $memoryAlertThreshold)
                    thresholdRow(english ? "Free disk threshold" : "磁盘可用空间阈值", unit: "%", value: $diskAlertThreshold)
                    thresholdRow(english ? "Network rate threshold" : "网络速率阈值", unit: "MB/s", value: $networkAlertThreshold)
                    thresholdRow(english ? "Low battery (on battery power)" : "低电量阈值（仅电池供电）", unit: "%", value: $batteryAlertThreshold)
                    Picker(L10n.text(english ? "Temperature alert" : "温度预警"), selection: $thermalAlertThreshold) {
                        Text(L10n.text(english ? "High temperature" : "高温时提醒")).tag(2.0)
                        Text(L10n.text(english ? "Severe overheating" : "严重过热时提醒")).tag(3.0)
                    }
                    HStack {
                        Button(L10n.text(english ? "Save Alert Thresholds" : L10n.text("保存预警阈值"))) { saveAlertThresholds() }
                        Button(L10n.text(english ? "Test Alert" : L10n.text("测试预警"))) { sendTestNotification() }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("DockLock")
                    Toggle(L10n.text("启用 DockLock"), isOn: Binding(
                        get: { dockLockEnabled },
                        set: { enabled in
                            guard enabled != dockLockEnabled else { return }
                            dockLockEnabled = DashboardWindow.toggleDockLock()
                        }
                    ))
                    Toggle(L10n.text("Dock 偏离时自动拉回"), isOn: $autoSnap)
                        .onChange(of: autoSnap) { _, enabled in AppSettings.shared.autoSnap = enabled }
                    HStack {
                        Text(L10n.text("屏幕边缘拦截厚度 (pt)"))
                        Spacer()
                        TextField("6", value: $edgeMargin, format: .number)
                            .frame(width: 60)
                            .onChange(of: edgeMargin) { _, value in if let checked = SettingValue.validated(value, key: "edgeMargin") { AppSettings.shared.edgeMargin = checked } else { edgeMargin = SettingValue.read("edgeMargin", fallback: 6) } }
                    }
                    HStack {
                        Text(L10n.text("目标显示器"))
                        Spacer()
                        Picker(L10n.text("目标显示器"), selection: $dockLockTarget) {
                            Text(L10n.text("自动（主屏优先）")).tag("builtin")
                            ForEach(DashboardWindow.dockLockScreens, id: \.id) { screen in
                                Text("\(screen.name) · \(screen.size)").tag(String(screen.id))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: dockLockTarget) { _, value in DashboardWindow.setDockLockTarget(value) }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.text(english ? "Home Icons" : L10n.text("首页功能图标")))
                    ForEach(modules.filter { $0.2 != .preferences }, id: \.0) { title, _, module in
                        Toggle(L10n.text(localized(title)), isOn: visibilityBinding(module))
                    }
                }
                Button(L10n.text(english ? "Shortcuts…" : L10n.text("快捷键…"))) {
                    showingPreferences = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingHotkeySettings = true }
                }
                HStack {
                    Spacer()
                Button(L10n.text(english ? "Done" : L10n.text("完成"))) { showingPreferences = false }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 320)
            .environment(\.font, .system(size: scaledFontSize))
            .onChange(of: statusMetricsRaw) { _, _ in
                NotificationCenter.default.post(name: .statusMetricsChanged, object: nil)
            }
            .onChange(of: english) { _, _ in
                NotificationCenter.default.post(name: .statusMetricsChanged, object: nil)
            }
        }
        .onAppear {
            if !screenRecorderAdded && AppSettings.shared.supportsWrites {
                if !stableVisibleModulesRaw.isEmpty {
                    var ids = stableVisibleModulesRaw.split(separator: ",").map(String.init)
                    if !ids.contains("screenRecorder") { ids.append("screenRecorder") }
                    stableVisibleModulesRaw = ids.joined(separator: ",")
                }
                screenRecorderAdded = true
            }
            if !diagnosticsAdded && AppSettings.shared.supportsWrites {
                if !stableVisibleModulesRaw.isEmpty {
                    var ids = stableVisibleModulesRaw.split(separator: ",").map(String.init)
                    if !ids.contains("networkDiagnostics") { ids.append("networkDiagnostics") }
                    stableVisibleModulesRaw = ids.joined(separator: ",")
                }
                diagnosticsAdded = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: DockLock.stateChanged)) { _ in
            dockLockEnabled = DashboardWindow.dockLockEnabled
        }
        .sheet(isPresented: $showingHelp) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(english ? "AI Lock Help" : L10n.text("AI Lock 帮助说明"))).font(.headline)
                Text(L10n.text(english ? "Use feature icons to open tools. Cache cleaning only clears user app caches after confirmation." : L10n.text("点击功能图标打开对应工具。缓存清理仅清理用户应用缓存，并在操作前要求确认。")))
                Text(L10n.format("当前版本：%{0}", arguments: [String(describing: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")]))
                Button(L10n.text(english ? "Check for Updates" : L10n.text("检查新版本"))) { NSWorkspace.shared.open(URL(string: "https://github.com/laoguzhe/AI-Lock/releases")!) }
                Text(L10n.text("laoguzhe@gmail.com"))
                HStack { Spacer(); Button(L10n.text(english ? "Done" : L10n.text("完成"))) { showingHelp = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(20).frame(width: 340)
        }
        .sheet(isPresented: $showingHotkeySettings) {
            HotkeySettingsView(english: english)
        }
    }

    private func metric(_ title: String, symbol: String, value: String, isAlert: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 24 * uiScale))
                .foregroundStyle(.secondary)
                .frame(width: 28 * uiScale, height: 28 * uiScale)
            Text(value)
                .font(.system(size: 16 * uiScale, weight: .light, design: .monospaced))
                .foregroundStyle(isAlert ? Color.red : Color.primary)
        }
        .frame(maxWidth: .infinity, minHeight: 44 * uiScale)
        .padding(.horizontal, 7)
        .delayedHelp(english
            ? (["CPU": "Current CPU usage across all cores.", "内存": "Used memory as a percentage of physical memory; alerts also track macOS memory pressure.", "硬盘": "Used disk space as a percentage of capacity; alerts track remaining free space."][title] ?? title)
            : (["CPU": "当前 CPU 总体使用率，反映处理器的忙碌程度。", "内存": "已用内存占物理内存的比例，预警同时关注 macOS 内存压力。", "硬盘": "已用空间占磁盘容量的比例，剩余空间不足时预警。"][title] ?? title))
    }

    private func runSearch() {
        if let first = searchResults.first {
            search.open(first)
        } else {
            search.search(query) { results in searchResults = results; searchNeedsDiskAccess = search.requiresFullDiskAccess }
        }
    }

    private func percent(_ used: UInt64, _ total: UInt64) -> String {
        guard total > 0 else { return "--" }
        return String(format: "%.0f%%", Double(used) / Double(total) * 100)
    }

    private var diskIsLow: Bool {
        guard snapshot.diskTotal > 0 else { return false }
        let freeBytes = snapshot.diskTotal > snapshot.diskUsed ? snapshot.diskTotal - snapshot.diskUsed : 0
        let freePercent = Double(freeBytes) / Double(snapshot.diskTotal) * 100
        return freePercent <= alerts.threshold(for: .diskFreePercent)
    }

    private func rate(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .memory) + "/s"
    }

    private func metricBinding(_ metric: String) -> Binding<Bool> {
        Binding(
            get: { statusMetrics.contains(metric) },
            set: { enabled in
                if enabled { statusMetrics.insert(metric) }
                else { statusMetrics.remove(metric) }
            }
        )
    }

    private func thresholdRow(_ title: String, unit: String, value: Binding<Double>) -> some View {
        HStack {
            Text(L10n.text(title))
            Spacer()
            TextField(L10n.text(title), value: value, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 72)
            Text(L10n.text(unit)).foregroundStyle(.secondary)
        }
    }

    private func saveAlertThresholds() {
        let saved = SettingValue.saveThresholds([("alert.cpu", cpuAlertThreshold), ("alert.memory", memoryAlertThreshold), ("alert.diskFreePercent", diskAlertThreshold), ("alert.networkMB", networkAlertThreshold), ("alert.batteryPercent", batteryAlertThreshold), ("alert.thermalLevel", thermalAlertThreshold)])
        notificationStatus = saved ? "阈值已保存" : "阈值无效：CPU/内存/电量/磁盘 1–100%，网络 0.1–1000 MB/s。"
    }

    private func sendTestNotification() {
        NotificationCenter.default.post(name: .resourceAlertPreview, object: nil)
    }

    @State private var notificationStatus = ""

    private var orderedVisibleModules: [(String, String, DashboardWindow.Module)] {
        let visible = visibleModuleIDs
        let order = orderedModuleIDs
        return modules.filter { visible.contains($0.2.rawValue) }
            .sorted { (order.firstIndex(of: $0.2.rawValue) ?? Int.max) < (order.firstIndex(of: $1.2.rawValue) ?? Int.max) }
    }

    private var visibleModuleIDs: Set<String> {
        visibleModulesRaw.isEmpty
            ? Set(modules.map { $0.2.rawValue })
            : Set(visibleModulesRaw.split(separator: ",").map(String.init)).union([DashboardWindow.Module.preferences.rawValue, DashboardWindow.Module.dockLock.rawValue])
    }

    private var orderedModuleIDs: [String] {
        var saved = moduleOrderRaw.split(separator: ",").map(String.init)
        if !saved.contains(DashboardWindow.Module.menuBarOrganizer.rawValue),
           let dockIndex = saved.firstIndex(of: DashboardWindow.Module.dockLock.rawValue) {
            saved.insert(DashboardWindow.Module.menuBarOrganizer.rawValue, at: dockIndex + 1)
        }
        let known = modules.map { $0.2.rawValue }
        return saved + known.filter { !saved.contains($0) }
    }

    private func visibilityBinding(_ module: DashboardWindow.Module) -> Binding<Bool> {
        Binding(get: { visibleModuleIDs.contains(module.rawValue) }, set: { visible in
            var ids = visibleModuleIDs
            if visible { ids.insert(module.rawValue) } else { ids.remove(module.rawValue) }
            visibleModulesRaw = ids.joined(separator: ",")
        })
    }

    private func hideModule(_ module: DashboardWindow.Module) {
        guard module != .preferences else { return }
        var ids = visibleModuleIDs
        ids.remove(module.rawValue)
        visibleModulesRaw = ids.joined(separator: ",")
    }

    private func reorderModules(_ source: String, _ target: String) {
        var order = orderedVisibleModules.map { $0.2.rawValue }
        guard let sourceIndex = order.firstIndex(of: source), let targetIndex = order.firstIndex(of: target), sourceIndex != targetIndex else { return }
        let moved = order.remove(at: sourceIndex)
        order.insert(moved, at: targetIndex)
        let hidden = orderedModuleIDs.filter { !order.contains($0) }
        moduleOrderRaw = (order + hidden).joined(separator: ",")
    }

    private func localized(_ title: String) -> String { L10n.text(title) }

    private func description(for module: DashboardWindow.Module, title: String) -> String {
        let descriptions: [DashboardWindow.Module: String] = [
            .dockLock: "配置 DockLock 目标屏幕、锁定边缘和自动拉回行为。",
            .files: "观察本机应用启动、网络连接和可用的文件审计事件。",
            .processes: "查看进程资源占用并管理进程。",
            .network: "查看当前网络连接和活动流量。",
            .networkDiagnostics: "测试网络速度、多节点、多线路、DNS、路由和本机网段配置。",
            .screenRecorder: "录制显示器画面和系统声音，并保存为 QuickTime 视频。",
            .logs: "仅查看 AI Lock 当前进程最近的应用日志。",
            .clipboard: "查看本机剪贴板历史记录。",
            .settings: "设置 CPU、磁盘和网络监控预警。",
            .preferences: "设置语言、字体大小和状态栏指标。",
            .search: "搜索并打开本机应用或文件。",
            .cacheCleaner: "扫描用户缓存，分类展示并在确认后清理。",
            .uninstaller: "卸载应用并预览可识别的用户级残留。",
            .launchItems: "检查开机登录项和后台启动项目。"
        ]
        return descriptions[module] ?? title
    }
}

private struct NetworkSparkline: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    let samples: [NetworkHistoryPoint]
    @State private var pointerX: CGFloat?

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        let maximum = max(samples.map(\.bytesPerSecond).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.format("峰值  %{0}", arguments: [String(describing: rate(maximum))]))
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.secondary)
            GeometryReader { geometry in
                let now = Date.now
                let window: TimeInterval = 60 * 60
                let cutoff = now.addingTimeInterval(-window)
                let selected = selectedSample(in: geometry.size.width, cutoff: cutoff, window: window)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for fraction in stride(from: 0.0, through: 1.0, by: 0.25) {
                            let y = geometry.size.height * fraction
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                        }
                        for fraction in stride(from: 0.0, through: 1.0, by: 1.0 / 12.0) {
                            let x = geometry.size.width * fraction
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                    }
                    .stroke(.quaternary, lineWidth: 0.5)

                    Path { path in
                        for (index, point) in samples.enumerated() {
                            let x = geometry.size.width * CGFloat(point.timestamp.timeIntervalSince(cutoff) / window)
                            let y = geometry.size.height * (1 - CGFloat(point.bytesPerSecond / maximum))
                            let position = CGPoint(x: min(max(x, 0), geometry.size.width), y: y)
                            if index == 0 || point.timestamp.timeIntervalSince(samples[index - 1].timestamp) > 90 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                    }
                    .stroke(.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))

                    if let selected {
                        let x = geometry.size.width * CGFloat(selected.timestamp.timeIntervalSince(cutoff) / window)
                        let y = geometry.size.height * (1 - CGFloat(selected.bytesPerSecond / maximum))
                        Path { path in
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                        }
                        .stroke(.secondary.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        Circle().fill(.blue).frame(width: 7, height: 7).position(x: x, y: y)
                        Text(L10n.text("\(selected.timestamp.formatted(date: .omitted, time: .standard))  ·  \(rate(selected.bytesPerSecond))" + (selected.observedSeconds.map { L10n.format(" · 观测 %{0} 秒", arguments: [String(describing: Int($0))]) } ?? "")))
                            .font(.system(size: 10, design: .monospaced))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                            .position(x: min(max(x, 105), geometry.size.width - 105), y: 12)
                    }

                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): pointerX = location.x
                    case .ended: pointerX = nil
                    }
                }
            }
        }
    }

    private func selectedSample(in width: CGFloat, cutoff: Date, window: TimeInterval) -> NetworkHistoryPoint? {
        guard let pointerX, width > 0, !samples.isEmpty else { return nil }
        let target = cutoff.addingTimeInterval(window * Double(min(max(pointerX / width, 0), 1)))
        return samples.min { abs($0.timestamp.timeIntervalSince(target)) < abs($1.timestamp.timeIntervalSince(target)) }
    }

    private func rate(_ bytes: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: Int64(bytes)), countStyle: .memory) + "/s"
    }
}

private struct HotkeySettingsView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @State private var registrationStatus = ""
    @State private var isCapturing = false
    @State private var shortcutTitle = DashboardWindow.quickActionShortcutTitle
    @State private var recorderShortcutTitle = DashboardWindow.screenRecorderShortcutTitle
    @State private var isCapturingRecorderShortcut = false
    let english: Bool

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(english ? "Quick Actions" : "快捷检索"))
                        .font(.system(size: 14, weight: .medium))
                    Text(L10n.text(english ? "Click the shortcut to change it." : "点击快捷键即可修改。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                QuickActionShortcutRecorder(title: isCapturing
                    ? L10n.text(english ? "Press shortcut…" : "按下快捷键…")
                    : (DashboardWindow.hasCustomQuickActionShortcut ? shortcutTitle : L10n.text(english ? "⌘ Twice" : "⌘ 两次")),
                    isCapturing: isCapturing,
                    recordingChanged: { isCapturing = $0 },
                    onCapture: { keyCode, modifiers in
                        DashboardWindow.saveQuickActionShortcut(keyCode: keyCode, modifiers: modifiers)
                        shortcutTitle = DashboardWindow.quickActionShortcutTitle
                        isCapturing = false
                    },
                    onCancel: { isCapturing = false })
                if DashboardWindow.hasCustomQuickActionShortcut {
                    Button(L10n.text(english ? "Reset" : "恢复默认")) {
                        DashboardWindow.resetQuickActionShortcut()
                        shortcutTitle = DashboardWindow.quickActionShortcutTitle
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text(english ? "Screen Recorder" : "录屏工具"))
                        .font(.system(size: 14, weight: .medium))
                    Text(L10n.text(english ? "Press the shortcut to start or stop recording." : "按下快捷键即可开始或停止录屏。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                QuickActionShortcutRecorder(title: isCapturingRecorderShortcut
                    ? L10n.text(english ? "Press shortcut…" : "按下快捷键…")
                    : recorderShortcutTitle,
                    isCapturing: isCapturingRecorderShortcut,
                    recordingChanged: { isCapturingRecorderShortcut = $0 },
                    onCapture: { keyCode, modifiers in
                        DashboardWindow.saveScreenRecorderShortcut(keyCode: keyCode, modifiers: modifiers)
                        recorderShortcutTitle = DashboardWindow.screenRecorderShortcutTitle
                        isCapturingRecorderShortcut = false
                    },
                    onCancel: { isCapturingRecorderShortcut = false })
                if UserDefaults.standard.bool(forKey: "screenRecorder.shortcut.enabled") {
                    Button(L10n.text(english ? "Reset" : "恢复默认")) {
                        DashboardWindow.resetScreenRecorderShortcut()
                        recorderShortcutTitle = DashboardWindow.screenRecorderShortcutTitle
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            if !registrationStatus.isEmpty {
                Text(L10n.text(registrationStatus)).foregroundStyle(.secondary).font(.caption)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            registrationStatus = DashboardWindow.refreshGlobalHotkeys().joined(separator: "\n")
            guard !CGPreflightListenEventAccess() else { return }
            _ = CGRequestListenEventAccess()
            registrationStatus = L10n.text(english
                ? "Input Monitoring is required. System Settings has been opened."
                : "需要输入监控权限，已自动打开系统设置。")
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

struct QuickActionShortcutRecorder: NSViewRepresentable {
    let title: String
    let isCapturing: Bool
    let recordingChanged: (Bool) -> Void
    let onCapture: (UInt16, NSEvent.ModifierFlags) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> QuickActionShortcutCaptureButton {
        let button = QuickActionShortcutCaptureButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.recordingChanged = recordingChanged
        button.onCapture = onCapture
        button.onCancel = onCancel
        return button
    }

    func updateNSView(_ button: QuickActionShortcutCaptureButton, context: Context) {
        button.title = title
        button.isCapturing = isCapturing
        button.recordingChanged = recordingChanged
        button.onCapture = onCapture
        button.onCancel = onCancel
    }
}

final class QuickActionShortcutCaptureButton: NSButton {
    var isCapturing = false
    var recordingChanged: ((Bool) -> Void)?
    var onCapture: ((UInt16, NSEvent.ModifierFlags) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        isCapturing = true
        recordingChanged?(true)
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isCapturing else { return super.keyDown(with: event) }
        if event.keyCode == UInt16(kVK_Escape) {
            isCapturing = false
            onCancel?()
            return
        }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard !modifiers.intersection([.command, .option, .control, .shift]).isEmpty else { return }
        isCapturing = false
        onCapture?(event.keyCode, modifiers)
    }
}

private final class PreferencesWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: LumenWindowMetrics.size(for: .preferences)),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.text("设置")
        window.minSize = LumenWindowMetrics.minimumSize(for: .preferences)
        window.backgroundColor = canvas
        window.appearance = DashboardWindow.preferredAppearance
        window.contentViewController = NSHostingController(rootView: LumenPreferencesView())
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: L10n.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance),
                                              name: .appearanceModeChanged, object: nil)
        window.center()
    }

    @objc private func refreshLanguage() {
        if let window { NativeLocalization.refresh(window); window.title = L10n.text("设置") }
    }

    @objc private func refreshAppearance() {
        window?.appearance = DashboardWindow.preferredAppearance
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct PreferencesWindowView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    private let sections = ["通用设置", "菜单栏收纳", "系统扩展", "监控预警", "DockLock", "首页图标", "快捷键", "帮助/关于"]
    @AppStorage("preferences.selectedSection") private var selection = "通用设置"
    @AppStorage("overview.language") private var selectedEnglish = false
    @AppStorage("overview.followSystemLanguage") private var followSystemLanguage = true
    @AppStorage("appearance.mode") private var appearanceMode = "system"
    private var english: Bool { L10n.isEnglish }
    private var languageSelection: Binding<String> {
        Binding(get: { followSystemLanguage ? "system" : (selectedEnglish ? "en" : "zh") }, set: { value in
            followSystemLanguage = value == "system"
            if value != "system" { selectedEnglish = value == "en" }
            NotificationCenter.default.post(name: L10n.changed, object: nil)
        })
    }
    @AppStorage("overview.fontScale.v1") private var fontSize = 1.0
    @AppStorage("overview.statusMetrics") private var statusMetricsRaw = ""
    @State private var cpu = AppSettings.shared.alerts.cpu
    @State private var memory = AppSettings.shared.alerts.memory
    @State private var disk = AppSettings.shared.alerts.diskFreePercent
    @State private var network = AppSettings.shared.alerts.networkMB
    @State private var battery = AppSettings.shared.alerts.batteryPercent
    @State private var thermal = AppSettings.shared.alerts.thermalLevel
    @AppStorage("alert.camera.enabled") private var cameraMonitoringEnabled = false
    @AppStorage("alert.microphone.enabled") private var microphoneMonitoringEnabled = false
    @State private var enabled = DashboardWindow.dockLockEnabled
    @State private var target = DashboardWindow.dockLockTargetSetting
    @State private var autoSnap = AppSettings.shared.autoSnap
    @State private var edgeMargin = SettingValue.read("edgeMargin", fallback: 6)
    @AppStorage("overview.visibleModules.v1") private var stableVisibleModulesRaw = ""
    private var visibleModulesRaw: String {
        get { AppSettings.moduleTitleCSV(stableVisibleModulesRaw) }
        nonmutating set { guard AppSettings.shared.supportsWrites else { return }; let stable = AppSettings.stableModuleCSV(newValue); stableVisibleModulesRaw = stable.isEmpty ? "__none__" : stable }
    }
    @State private var clipboardRetention = ClipboardHistory.shared.retentionDays
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.text(english ? "SETTINGS" : L10n.text("设置"))).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
                ForEach(sections, id: \.self) { section in
                    Button { selection = section } label: {
                        Label(L10n.text(english ? englishTitle(section) : section), systemImage: symbol(for: section))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).padding(.horizontal, 10)
                            .background(selection == section ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).delayedHelp(L10n.text(IconHelp.description(for: section))).padding(.horizontal, 8)
                }
                Spacer()
            }
            .frame(width: 190).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    sectionContent
                }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }
        }
        .onChange(of: statusMetricsRaw) { _, _ in NotificationCenter.default.post(name: .statusMetricsChanged, object: nil) }
        .onChange(of: english) { _, _ in NotificationCenter.default.post(name: .statusMetricsChanged, object: nil); NotificationCenter.default.post(name: L10n.changed, object: nil) }
        .onAppear {
            if selection == "通用" { selection = "通用设置" }
            applyAppearance()
        }
        .onChange(of: appearanceMode) { _, _ in
            applyAppearance()
            NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
        }
        .preferredColorScheme(appearanceMode == "light" ? .light : appearanceMode == "dark" ? .dark : nil)
    }

    private func applyAppearance() {
        NSApp.appearance = DashboardWindow.preferredAppearance
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled { try service.register() } else { try service.unregister() }
        } catch {
            log("开机自启切换失败：\(error.localizedDescription)")
            launchAtLogin = service.status == .enabled
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selection {
        case "菜单栏收纳":
            MenuBarOrganizerSettingsView()
        case "通用设置":
            Picker(L10n.text(english ? "Language" : L10n.text("语言")), selection: languageSelection) {
                Text(L10n.text("中文")).tag("zh")
                Text("English").tag("en")
                Text(L10n.text(english ? "Follow System" : L10n.text("跟随系统"))).tag("system")
            }
            HStack(spacing: 16) {
                Picker(L10n.text(english ? "Appearance" : L10n.text("样式")), selection: $appearanceMode) {
                    Text(L10n.text(english ? "Light" : L10n.text("浅色"))).tag("light")
                    Text(L10n.text(english ? "Dark" : L10n.text("深色"))).tag("dark")
                    Text(L10n.text(english ? "Follow System" : L10n.text("跟随系统"))).tag("system")
                }
                Picker(L10n.text(english ? "Text Size" : L10n.text("文字大小")), selection: $fontSize) { Text(L10n.text("小")).tag(0.9); Text(L10n.text("中")).tag(1.0); Text(L10n.text("大")).tag(1.15) }
            }
            GroupBox(L10n.text(english ? "Menu Bar Metrics" : L10n.text("状态栏指标"))) {
                HStack(spacing: 22) {
                    metricChoice("cpu", title: L10n.text("CPU"), symbol: "cpu")
                    metricChoice("memory", title: english ? "Memory" : "内存", symbol: "memorychip")
                    metricChoice("disk", title: english ? "Disk" : "硬盘", symbol: "internaldrive")
                    metricChoice("network", title: english ? "Network" : "网络", symbol: "network")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker(L10n.text("剪贴板历史保留期限"), selection: $clipboardRetention) { ForEach([1, 3, 7, 14, 30], id: \.self) { Text(L10n.format("保留 %{0} 天", arguments: [String(describing: $0)])).tag($0) } }.onChange(of: clipboardRetention) { _, value in ClipboardHistory.shared.retentionDays = value }
            Toggle(L10n.text(english ? "Launch at Login" : L10n.text("开机自启动")), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, value in setLaunchAtLogin(value) }
            Button(L10n.text(english ? "Quit AI Lock" : "退出 AI Lock")) { NSApplication.shared.terminate(nil) }

        case "系统扩展":
            ExtensionSettingsView()
        case "监控预警":
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 24) {
                    Toggle(isOn: $cameraMonitoringEnabled) {
                        Label(L10n.text(english ? "Monitor camera use" : "监视摄像头调用"), systemImage: "video.fill")
                    }
                        .onChange(of: cameraMonitoringEnabled) { _, _ in NotificationCenter.default.post(name: .mediaMonitoringSettingsChanged, object: nil) }
                    Toggle(isOn: $microphoneMonitoringEnabled) {
                        Label(L10n.text(english ? "Monitor microphone use" : "监视麦克风调用"), systemImage: "mic.fill")
                    }
                        .onChange(of: microphoneMonitoringEnabled) { _, _ in NotificationCenter.default.post(name: .mediaMonitoringSettingsChanged, object: nil) }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), alignment: .leading)], alignment: .leading, spacing: 10) {
                    thresholdRow("CPU 预警阈值", symbol: "cpu", unit: "%", value: $cpu)
                    thresholdRow("内存使用量预警阈值", symbol: "memorychip", unit: "%", value: $memory)
                    thresholdRow("磁盘可用空间阈值", symbol: "internaldrive", unit: "%", value: $disk)
                    thresholdRow("网络速率阈值", symbol: "network", unit: "MB/s", value: $network)
                    thresholdRow("低电量阈值（仅电池供电）", symbol: "battery.25percent", unit: "%", value: $battery)
                }
                HStack(spacing: 10) {
                    Label(L10n.text("温度预警"), systemImage: "thermometer")
                    Picker(L10n.text("温度预警"), selection: $thermal) {
                        Text(L10n.text("高温时提醒")).tag(2.0)
                        Text(L10n.text("严重过热时提醒")).tag(3.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                HStack {
                    Button(L10n.text("保存预警阈值")) { notificationStatus = SettingValue.saveThresholds([("alert.cpu", cpu), ("alert.memory", memory), ("alert.diskFreePercent", disk), ("alert.networkMB", network), ("alert.batteryPercent", battery), ("alert.thermalLevel", thermal)]) ? "阈值已保存" : "阈值无效：CPU/内存/电量/磁盘 1–100%，网络 0.1–1000 MB/s。" }
                    Button(L10n.text("测试预警")) { sendTestNotification() }
                }
                if !notificationStatus.isEmpty { Text(L10n.text(notificationStatus)).font(.caption).foregroundStyle(.secondary) }
            }
        case "DockLock":
            Text(L10n.text("锁定程序坞在你选择的显示器上。"))
                .foregroundStyle(.secondary)
            Toggle(L10n.text("Dock 偏离时自动拉回"), isOn: $autoSnap).onChange(of: autoSnap) { _, value in AppSettings.shared.autoSnap = value }
            HStack { Text(L10n.text("屏幕边缘拦截厚度 (pt)")); Spacer(); TextField("6", value: $edgeMargin, format: .number).frame(width: 80) }.onChange(of: edgeMargin) { _, value in if let checked = SettingValue.validated(value, key: "edgeMargin") { AppSettings.shared.edgeMargin = checked } else { edgeMargin = SettingValue.read("edgeMargin", fallback: 6) } }
            Picker(L10n.text("目标显示器"), selection: $target) { Text(L10n.text("自动（主屏优先）")).tag("builtin"); ForEach(DashboardWindow.dockLockScreens, id: \.id) { Text("\($0.name) · \($0.size)").tag(String($0.id)) } }.onChange(of: target) { _, value in DashboardWindow.setDockLockTarget(value) }
            ScreenTopologyView(screens: DashboardWindow.dockLockScreens)
        case "首页图标":
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(92)), count: 4), spacing: 14) {
                ForEach(DashboardWindow.Module.allCasesForPreferences, id: \.rawValue) { module in
                    Button { visibilityBinding(module).wrappedValue.toggle() } label: {
                        VStack(spacing: 6) {
                            Image(systemName: moduleSymbol(module))
                                .font(.system(size: 25, weight: .medium))
                            Text(L10n.text(module.displayTitle))
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                        }
                        .foregroundStyle(visibilityBinding(module).wrappedValue ? Color.accentColor : Color.secondary)
                        .frame(width: 86, height: 76)
                        .background(visibilityBinding(module).wrappedValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).delayedHelp(L10n.format("点击显示或隐藏首页的%{0}图标。", arguments: [L10n.text(module.displayTitle)]))
                }
            }
        case "快捷键":
            HotkeySettingsView(english: english)
        default:
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.text(english ? "AI Lock · Your Mac, at a glance" : L10n.text("AI Lock · 看见 Mac 的运行状态")))
                    .font(.title3.weight(.semibold))
                Text(english
                     ? "AI Lock is a native macOS utility for understanding system activity and keeping everyday tools close at hand. It brings resource monitoring, process and network views, app logs, quick search, clipboard history, hardware details, and multi-display Dock control into one place."
                     : "AI Lock 是一款原生 macOS 系统工具，帮助你了解电脑运行状况，并把常用维护能力集中在一处。你可以查看 CPU、内存、磁盘与网络状态，浏览进程、网络连接和应用日志，使用快速搜索与剪贴板历史，查看硬件信息，也可以将 Dock 固定在指定显示器。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(english
                     ? "Designed to run locally. Monitoring data and clipboard history stay on this Mac. Some capabilities require macOS permissions and can be enabled when needed."
                     : "AI Lock 面向本机使用：所有数据保存在本机，部分功能需要 macOS 权限，可在使用时按需授权。")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("\(english ? "Version" : L10n.text("版本"))：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"))
                Text(L10n.text(english ? "By the AI Lock developer" : L10n.text("laoguzhe@gmail.com")))
                Link(L10n.text(english ? "Project & Updates" : L10n.text("项目主页与更新")), destination: URL(string: "https://github.com/laoguzhe/AI-Lock")!)
            }
        }
    }

    private func metricBinding(_ key: String) -> Binding<Bool> {
        Binding(get: {
            let values = Set(statusMetricsRaw.split(separator: ",").map(String.init))
            if key == "network" {
                return values.contains("network") || values.contains("networkUpload") || values.contains("networkDownload")
            }
            return values.contains(key)
        }, set: { enabled in
            var values = Set(statusMetricsRaw.split(separator: ",").map(String.init))
            if key == "network" {
                values.remove("networkUpload")
                values.remove("networkDownload")
                if enabled { values.insert("network") } else { values.remove("network") }
            } else if enabled {
                values.insert(key)
            } else {
                values.remove(key)
            }
            statusMetricsRaw = values.sorted().joined(separator: ",")
        })
    }

    private func metricChoice(_ key: String, title: String, symbol: String) -> some View {
        let selected = metricBinding(key).wrappedValue
        return Button { metricBinding(key).wrappedValue.toggle() } label: {
            VStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: symbol).font(.system(size: 21)).foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 10)).foregroundStyle(Color.accentColor).offset(x: 6, y: -5) }
                }.frame(width: 34, height: 30)
                Text(L10n.text(title)).font(.caption).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }.buttonStyle(.plain)
        .delayedHelp(L10n.text(english ? "Show or hide \(title) beside the menu bar app icon." : L10n.format("在菜单栏程序图标右侧显示或隐藏%{0}指标。", arguments: [String(describing: title)])))
    }

    private func moduleSymbol(_ module: DashboardWindow.Module) -> String {
        ["DockLock 设置": "dock.rectangle", "快捷操作": "command", "菜单栏收纳": "menubar.rectangle", "安全活动": "shield.lefthalf.filled", "应用卸载": "app.dashed", "启动项检查": "rectangle.stack.badge.play", "进程管理": "cpu", "网络活动": "network", "网络诊断": "speedometer", "录屏工具": "record.circle", "显示器控制": "sun.max", "系统日志": "list.bullet.rectangle", "剪贴板历史": "clipboard", "系统健康检查": "stethoscope", "设置": "gearshape"][module.rawValue] ?? "square"
    }



    private func visibilityBinding(_ module: DashboardWindow.Module) -> Binding<Bool> {
        Binding(get: { visibleModulesRaw.isEmpty || visibleModulesRaw.split(separator: ",").contains(Substring(module.rawValue)) }, set: { visible in
            var values = Set(visibleModulesRaw.isEmpty ? DashboardWindow.Module.allCasesForPreferences.map(\.rawValue) : visibleModulesRaw.split(separator: ",").map(String.init)); if visible { values.insert(module.rawValue) } else { values.remove(module.rawValue) }; visibleModulesRaw = values.joined(separator: ",")
        })
    }

    private func thresholdRow(_ title: String, symbol: String, unit: String, value: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(L10n.text(title)).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                TextField("", value: value, format: .number).frame(width: 68)
                Text(L10n.text(unit)).foregroundStyle(.secondary)
                    .frame(width: 44, alignment: .leading)
            }
            .frame(width: 118, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @State private var notificationStatus = ""
    private func sendTestNotification() {
        NotificationCenter.default.post(name: .resourceAlertPreview, object: nil)
    }

    private func symbol(for section: String) -> String { ["通用设置": "slider.horizontal.3", "菜单栏收纳": "menubar.rectangle", "监控预警": "bell.badge", "DockLock": "dock.rectangle", "首页图标": "square.grid.2x2", "快捷键": "keyboard", "帮助/关于": "info.circle"] [section] ?? "gearshape" }
    private func englishTitle(_ section: String) -> String { L10n.text(section) }
}

extension Notification.Name {
    static let appearanceModeChanged = Notification.Name("appearanceModeChanged")
}

private extension DashboardWindow.Module {
    static var allCasesForPreferences: [DashboardWindow.Module] { [.menuBarOrganizer, .files, .uninstaller, .launchItems, .processes, .network, .networkDiagnostics, .displayBrightness, .screenRecorder, .logs, .clipboard, .cacheCleaner] }
}

struct ScreenTopologyView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    let screens: [DockLock.ScreenChoice]
    @State private var covered: Set<CGDirectDisplayID>
    private let toggle: (CGDirectDisplayID) -> Void
    init(screens: [DockLock.ScreenChoice], covered: Set<CGDirectDisplayID>? = nil, toggle: @escaping (CGDirectDisplayID) -> Void = DashboardWindow.toggleDisplayPrivacy) {
        self.screens = screens; self.toggle = toggle
        _covered = State(initialValue: covered ?? DashboardWindow.coveredDisplays)
    }
    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width - 32, 1)
            let availableHeight = max(proxy.size.height - 32, 1)
            let minX = screens.map(\.bounds.minX).min() ?? 0
            let minY = screens.map(\.bounds.minY).min() ?? 0
            let maxX = screens.map(\.bounds.maxX).max() ?? 1
            let maxY = screens.map(\.bounds.maxY).max() ?? 1
            let scale = min(availableWidth / max(maxX - minX, 1), availableHeight / max(maxY - minY, 1), 140 / max(screens.map(\.bounds.width).max() ?? 1, 1), 90 / max(screens.map(\.bounds.height).max() ?? 1, 1))
            let diagramWidth = (maxX - minX) * scale
            let diagramHeight = (maxY - minY) * scale
            let originX = (proxy.size.width - diagramWidth) / 2
            let originY = (proxy.size.height - diagramHeight) / 2
            ZStack {
                ForEach(screens, id: \.id) { screen in
                    Button {
                        toggle(screen.id)
                    } label: {
                        ZStack {
                            Image(nsImage: wallpaper(for: screen.id) ?? NSImage(systemSymbolName: "display", accessibilityDescription: nil)!)
                                .resizable().scaledToFit()
                            if covered.contains(screen.id) { Color.black.opacity(0.85) }
                        }
                        .frame(width: max(1, screen.bounds.width * scale - 4), height: max(1, screen.bounds.height * scale - 4))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .delayedHelp(L10n.text(L10n.isEnglish
                        ? "Click to test a display blackout; click the black screen to restore it. Press Esc to cancel the test, or ⌘⌃⇧Esc to clear all covers."
                        : "点击测试显示器黑屏；黑屏后点击该屏幕恢复。按 Esc 取消测试，或按 ⌘⌃⇧Esc 解除全部遮罩。"))
                    .accessibilityLabel(L10n.text(screen.name + L10n.text("，点击切换黑屏")))
                    .position(x: originX + (screen.bounds.midX - minX) * scale,
                              y: originY + (screen.bounds.midY - minY) * scale)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .clipped()
        }.frame(height: 150)
        .onReceive(NotificationCenter.default.publisher(for: .displayPrivacyChanged)) { _ in covered = DashboardWindow.coveredDisplays }
        Text(L10n.text(L10n.isEnglish
            ? "Click a display image to test a blackout; click the black screen to restore it. Press Esc to cancel the test."
            : "点击屏幕图片测试黑屏；黑屏后点击屏幕即可恢复。按 Esc 取消测试。"))
            .font(.caption).foregroundStyle(.secondary)
    }

    private func wallpaper(for id: CGDirectDisplayID) -> NSImage? {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }

}

extension Notification.Name {
    static let displayPrivacyChanged = Notification.Name("displayPrivacyChanged")
}

final class DisplayPrivacyCoverView: NSView {
    var restore: (() -> Void)?
    private let hintLabel = NSTextField(labelWithString: L10n.text("按 ESC取消黑屏测试"))
    private var hintTimer: Timer?
    private var remainingHintToggles = 4

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .systemOrange
        hintLabel.isBezeled = false
        hintLabel.drawsBackground = false
        hintLabel.isEditable = false
        hintLabel.isSelectable = false
        hintLabel.frame = NSRect(x: 16, y: 10, width: 180, height: 18)
        addSubview(hintLabel)

        hintTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.hintLabel.isHidden.toggle()
            self.remainingHintToggles -= 1
            if self.remainingHintToggles == 0 {
                self.hintLabel.isHidden = true
                timer.invalidate()
                self.hintTimer = nil
            }
        }
    }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { restore?() }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { hintTimer?.invalidate() }
}

private final class DisplayPrivacyCard: NSView {
    init(display: DockLock.ScreenChoice) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let preview = DelayedHelpButton(title: L10n.text(""), target: nil, action: nil)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isBordered = false
        preview.imagePosition = .imageOnly
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.target = self
        preview.action = #selector(togglePrivacy(_:))
        preview.tag = Int(display.id)
        preview.helpDescription = L10n.text("点击切换此显示器的隐私黑屏；点击黑屏恢复，⌘⌃⇧Esc 解除全部遮罩")
        preview.image = Self.previewImage(for: display.id)

        let caption = NSTextField(labelWithString: L10n.text("\(display.name) · \(display.size)"))
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.alignment = .center
        caption.font = .systemFont(ofSize: 11)

        addSubview(preview)
        addSubview(caption)
        NSLayoutConstraint.activate([
            preview.topAnchor.constraint(equalTo: topAnchor), preview.leadingAnchor.constraint(equalTo: leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: trailingAnchor), preview.heightAnchor.constraint(equalToConstant: 112),
            caption.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 5), caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor), caption.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func togglePrivacy(_ sender: NSButton) {
        DisplayPrivacyManager.shared.toggle(CGDirectDisplayID(sender.tag))
    }

    private static func previewImage(for displayID: CGDirectDisplayID) -> NSImage? {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }
        guard let screen, let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: wallpaper)
    }
}

private final class DisplayPrivacyManager {
    static let shared = DisplayPrivacyManager()
    private var overlays: [CGDirectDisplayID: NSWindow] = [:]
    private var blackoutTestIDs: Set<CGDirectDisplayID> = []
    var coveredIDs: Set<CGDirectDisplayID> { Set(overlays.keys) }
    private let defaultsKey = "privacyBlackoutDisplays"
    private var screenObserver: NSObjectProtocol?

    private init() {
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                               object: nil, queue: .main) { [weak self] _ in self?.reconcileScreens() }
        let saved = Set(UserDefaults.standard.array(forKey: defaultsKey) as? [UInt32] ?? [])
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  saved.contains(number.uint32Value), overlays.count < NSScreen.screens.count - 1 else { continue }
            show(number.uint32Value, on: screen)
        }
    }

    func toggle(_ displayID: CGDirectDisplayID) {
        if let window = overlays.removeValue(forKey: displayID) {
            blackoutTestIDs.remove(displayID)
            window.close()
        } else if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) {
            show(displayID, on: screen)
        }
        UserDefaults.standard.set(Array(overlays.keys), forKey: defaultsKey)
        NotificationCenter.default.post(name: .displayPrivacyChanged, object: nil)
    }

    func cancelBlackoutTest() {
        guard !blackoutTestIDs.isEmpty else { return }
        for displayID in blackoutTestIDs {
            overlays.removeValue(forKey: displayID)?.close()
        }
        blackoutTestIDs.removeAll()
        UserDefaults.standard.set(Array(overlays.keys), forKey: defaultsKey)
        NotificationCenter.default.post(name: .displayPrivacyChanged, object: nil)
    }

    func clearAll() {
        overlays.values.forEach { $0.close() }
        overlays.removeAll()
        blackoutTestIDs.removeAll()
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        NotificationCenter.default.post(name: .displayPrivacyChanged, object: nil)
    }

    private func reconcileScreens() {
        let screens = NSScreen.screens
        let active = Set(screens.compactMap { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value })
        for id in Array(overlays.keys) where !active.contains(id) { overlays.removeValue(forKey: id)?.close() }
        // Hot unplug must not leave the only remaining display covered.
        if !active.isEmpty, active.isSubset(of: Set(overlays.keys)), let id = active.first {
            overlays.removeValue(forKey: id)?.close()
        }
        for screen in screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { continue }
            overlays[id]?.setFrame(screen.frame, display: true)
        }
        UserDefaults.standard.set(Array(overlays.keys), forKey: defaultsKey)
        NotificationCenter.default.post(name: .displayPrivacyChanged, object: nil)
    }

    deinit { if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) } }

    private func show(_ displayID: CGDirectDisplayID, on screen: NSScreen) {
        // 用非激活 NSPanel：.regular 激活策略下，普通 NSWindow 无法在原点左侧/上方的
        // 屏幕（x/y 为负）上上屏，改用 nonactivatingPanel 可正常覆盖所有屏幕。
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        let cover = DisplayPrivacyCoverView(frame: NSRect(origin: .zero, size: screen.frame.size))
        cover.restore = { [weak self] in self?.toggle(displayID) }
        panel.contentView = cover
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.black.cgColor
        panel.backgroundColor = .black
        panel.isOpaque = true
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isReleasedWhenClosed = false
        panel.setFrame(screen.frame, display: true)
        overlays[displayID] = panel
        blackoutTestIDs.insert(displayID)
        panel.orderFrontRegardless()
    }
}

private final class LogTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [SystemLogGroup]

    init(entries: [SystemLogGroup]) { self.entries = entries }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row), let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == "message" }) else { return 34 }
        let message = entries[row].title as NSString
        let width = max(column.width - 16, 40)
        let bounds = message.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                          attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return max(34, ceil(bounds.height) + 12)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let group = entries[row]
        let entry = group.latest
        if identifier == "level" {
            let cell = NSTableCellView()
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = NSImage(systemSymbolName: symbol(for: entry.level), accessibilityDescription: L10n.text(entry.level.rawValue))
            image.contentTintColor = entry.needsAttention ? .systemOrange : .secondaryLabelColor
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 14),
                image.heightAnchor.constraint(equalToConstant: 14)
            ])
            return cell
        }
        let cell = NSTableCellView()
        let text = NSTextField(wrappingLabelWithString: L10n.text(""))
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = ink
        if identifier == "message" {
            text.lineBreakMode = .byWordWrapping
            text.usesSingleLineMode = false
            text.maximumNumberOfLines = 0
        } else {
            text.lineBreakMode = .byTruncatingTail
            text.usesSingleLineMode = true
        }
        switch identifier {
        case "time": text.stringValue = entry.formattedTime
        case "process": text.stringValue = entry.process
        case "message": text.stringValue = group.title
        default: return nil
        }
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }

    private func symbol(for level: SystemLogLevel) -> String {
        switch level {
        case .all: return "line.3.horizontal.decrease.circle"
        case .debug: return "ladybug"
        case .info: return "info.circle"
        case .notice: return "bell"
        case .error: return "exclamationmark.circle"
        case .fault: return "xmark.octagon"
        }
    }
}



private final class SearchTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var results: [SearchResult]
    init(results: [SearchResult]) { self.results = results }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let result = results[row]
        let cell = NSTextField(wrappingLabelWithString: L10n.text(""))
        cell.font = .systemFont(ofSize: 12); cell.textColor = ink
        cell.lineBreakMode = column == "path" ? .byTruncatingMiddle : .byTruncatingTail
        switch column {
        case "kind": cell.stringValue = L10n.text(result.typeLabel)
        case "title":
            let container = NSView()
            let image = result.makeIconView(size: 20)
            cell.stringValue = result.title
            [image, cell].forEach { $0.translatesAutoresizingMaskIntoConstraints = false; container.addSubview($0) }
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 20), image.heightAnchor.constraint(equalToConstant: 20),
                cell.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 6),
                cell.trailingAnchor.constraint(equalTo: container.trailingAnchor), cell.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            return container
        case "path": cell.stringValue = result.path
        default: return nil
        }
        return cell
    }
}

private struct ShortcutReorderDelegate: DropDelegate {
    let module: String
    let order: [String]
    @Binding var dragging: String?
    let update: (String, String) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != module else { return }
        update(dragging, module)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

private final class CacheTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [CacheEntry]
    private var applicationCache: [String: (String, NSImage?)] = [:]

    init(entries: [CacheEntry]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    private func application(for entry: CacheEntry) -> (String, NSImage?) {
        if let cached = applicationCache[entry.name] { return cached }
        let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.name)
        let appName = appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String }
            ?? appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleName") as? String }
            ?? entry.name
        let icon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let resolved = (appName, icon)
        applicationCache[entry.name] = resolved
        return resolved
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        if column == "name" {
            let cell = NSTableCellView()
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            let app = application(for: entry)
            imageView.image = app.1 ?? NSImage(named: NSImage.applicationIconName)
            let text = NSTextField(labelWithString: app.0)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: 12); text.textColor = ink
            text.usesSingleLineMode = true; text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(imageView); cell.addSubview(text)
            cell.imageView = imageView; cell.textField = text
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 20), imageView.heightAnchor.constraint(equalToConstant: 20),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        guard column == "size" else { return nil }
        let cell = NSTextField(labelWithString: L10n.text(CacheCleaner.formattedSize(entry.size)))
        cell.font = .systemFont(ofSize: 12); cell.textColor = ink
        return cell
    }
}

private final class InstalledAppDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [InstalledApplication]
    init(entries: [InstalledApplication]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let app = entries[row]
        let text: String
        switch column {
        case "name": text = app.name
        case "size": text = CacheCleaner.formattedSize(app.size)
        case "path": text = app.url.path
        default: return nil
        }
        if column == "name" {
            let container = NSView()
            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = NSWorkspace.shared.icon(forFile: app.url.path)
            icon.imageScaling = .scaleProportionallyUpOrDown
            let name = NSTextField(labelWithString: text)
            name.translatesAutoresizingMaskIntoConstraints = false
            name.font = .systemFont(ofSize: 12)
            name.textColor = ink
            name.lineBreakMode = .byTruncatingTail
            container.addSubview(icon)
            container.addSubview(name)
            NSLayoutConstraint.activate([
                icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                icon.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                icon.widthAnchor.constraint(equalToConstant: 28), icon.heightAnchor.constraint(equalToConstant: 28),
                name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
                name.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
                name.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            return container
        }
        let cell = NSTextField(labelWithString: text); cell.font = .systemFont(ofSize: 12); cell.textColor = ink
        cell.lineBreakMode = column == "path" ? .byTruncatingMiddle : .byTruncatingTail
        return cell
    }
}

private final class StartupItemDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onRepair: ((StartupItem) -> Void)?
    var onDelete: ((StartupItem) -> Void)?
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let table, items.indices.contains(table.clickedRow) else { return }
        let item = items[table.clickedRow]
        let repair = NSMenuItem(title: L10n.text("修复建议…"), action: #selector(repairItem(_:)), keyEquivalent: "")
        repair.target = self; repair.representedObject = item; menu.addItem(repair)
        let entry = NSMenuItem(title: L10n.text("删除启动项…"), action: #selector(deleteItem(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = item
        menu.addItem(entry)
    }
    @objc private func repairItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StartupItem else { return }
        onRepair?(item)
    }
    @objc private func deleteItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? StartupItem else { return }
        onDelete?(item)
    }
    var items: [StartupItem]
    private weak var table: NSTableView?
    private var iconCache: [String: NSImage] = [:]
    init(items: [StartupItem], table: NSTableView) { self.items = items; self.table = table }
    func reload() { table?.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    private func icon(for item: StartupItem) -> NSImage? {
        if let cached = iconCache[item.id] { return cached }

        let programURL = URL(fileURLWithPath: item.program)
        var icon: NSImage?
        if item.program.hasPrefix("/"), let appURL = programURL.pathComponents
            .enumerated()
            .first(where: { $0.element.hasSuffix(".app") })
            .map({ URL(fileURLWithPath: NSString.path(withComponents: Array(programURL.pathComponents.prefix($0.offset + 1)))) }),
           FileManager.default.fileExists(atPath: appURL.path) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        }

        if icon == nil, !item.label.isEmpty,
           let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: item.label) {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        }
        if icon == nil, item.program.hasPrefix("/"), FileManager.default.fileExists(atPath: item.program) {
            icon = NSWorkspace.shared.icon(forFile: item.program)
        }

        if let icon { iconCache[item.id] = icon }
        return icon
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        if column == "label" {
            let cell = NSTableCellView()
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = icon(for: item) ?? NSImage(named: NSImage.applicationIconName)
            let text = NSTextField(labelWithString: item.label)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: 12)
            text.lineBreakMode = .byTruncatingTail
            text.usesSingleLineMode = true
            cell.addSubview(imageView)
            cell.addSubview(text)
            cell.imageView = imageView
            cell.textField = text
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 28),
                imageView.heightAnchor.constraint(equalToConstant: 28),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let value: String
        switch column {
        case "kind": value = item.kind
        case "enabled": value = L10n.statusList(item.startupStatus)
        case "program": value = ["未知", "未验证"].contains(item.program) ? L10n.text(item.program) : item.program
        default: return nil
        }
        let cell = NSTextField(labelWithString: column == "kind" || column == "enabled" ? L10n.text(value) : value); cell.font = .systemFont(ofSize: 12); cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }
}





private struct CommandPaletteCommand: Identifiable {
    enum Action { case scanLargeFiles }
    let title: String
    let keywords: String
    let module: DashboardWindow.Module?
    let action: Action?
    var id: String { title }

    static let all: [CommandPaletteCommand] = [
        .init(title: L10n.text("打开安全活动 / 分析文件"), keywords: "security file activity 文件", module: .files, action: nil),
        .init(title: L10n.text("打开系统健康检查"), keywords: "health cache 清理 缓存", module: .cacheCleaner, action: nil),
        .init(title: L10n.text("打开应用卸载"), keywords: "uninstall app 卸载 应用", module: .uninstaller, action: nil),
        .init(title: L10n.text("打开启动项检查"), keywords: "startup login background 后台 登录项", module: .launchItems, action: nil),
        .init(title: L10n.text("打开网络诊断"), keywords: "speed dns ping route 网络测速 诊断", module: .networkDiagnostics, action: nil),
        .init(title: L10n.text("打开录屏工具"), keywords: "screen record capture 录屏 屏幕录制", module: .screenRecorder, action: nil),
        .init(title: L10n.text("打开网络活动"), keywords: "network connection 网络 连接", module: .network, action: nil),
        .init(title: L10n.text("打开进程管理"), keywords: "process cpu memory 进程", module: .processes, action: nil),
        .init(title: L10n.text("打开 AI Lock 应用日志"), keywords: "log 日志", module: .logs, action: nil),
        .init(title: L10n.text("打开剪贴板历史"), keywords: "clipboard 剪贴板", module: .clipboard, action: nil),
        .init(title: L10n.text("查看文件访问审计"), keywords: "audit 文件 访问 审计", module: nil, action: .scanLargeFiles)
    ]
}

private final class CommandPaletteDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var commands = CommandPaletteCommand.all
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row) else { return nil }
        return NSTextField(labelWithString: L10n.text(commands[row].title))
    }
}



extension Notification.Name {
    static let processSelectionChanged = Notification.Name("AILockProcessSelectionChanged")
    static let statusMetricsChanged = Notification.Name("AILockStatusMetricsChanged")
}

private final class ApplicationUninstallerModel: ObservableObject {
    @Published var apps: [InstalledApplication] = []
    @Published var selected: Set<String> = []
    @Published var extensionItems: [UninstallableExtension] = []
    @Published var selectedExtensions: Set<String> = []
    @Published var busy = false
    @Published var scanning = false
    @Published var status = "正在扫描应用…"
}

private struct ApplicationUninstallerView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @ObservedObject var model: ApplicationUninstallerModel
    let refresh: () -> Void
    let uninstall: () -> Void
    let uninstallExtensions: () -> Void
    @State private var detail: InstalledApplication?
    @State private var showingExtensions = false
    @State private var selectedCategory: ExtensionUninstallCategory = .installers

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: $showingExtensions) {
                    Text(L10n.text("应用")).tag(false)
                    Text(L10n.text("扩展卸载")).tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 190)
                Spacer()
                if showingExtensions {
                    Text(L10n.format("已选 %{0} 项", arguments: [String(describing: model.selectedExtensions.count)])).foregroundStyle(.secondary)
                    Button(L10n.text(categoryItems.allSatisfy { model.selectedExtensions.contains($0.id) } && !categoryItems.isEmpty ? "取消全选" : "全选")) {
                        let ids = Set(categoryItems.map(\.id))
                        if !ids.isEmpty && ids.isSubset(of: model.selectedExtensions) { model.selectedExtensions.subtract(ids) }
                        else { model.selectedExtensions.formUnion(ids) }
                    }.disabled(model.busy || categoryItems.isEmpty)
                } else {
                    Text(L10n.format("已选 %{0} 个应用", arguments: [String(describing: model.selected.count)])).foregroundStyle(.secondary)
                    Button(L10n.text(model.selected.count == model.apps.count && !model.apps.isEmpty ? "取消全选" : "全选")) {
                        model.selected = model.selected.count == model.apps.count ? [] : Set(model.apps.map(\.id))
                    }.disabled(model.busy || model.apps.isEmpty)
                }
                Button(action: refresh) { Label(L10n.text("刷新"), systemImage: "arrow.clockwise") }.disabled(model.busy || model.scanning)
                Button(action: showingExtensions ? uninstallExtensions : uninstall) {
                    Label(L10n.format(showingExtensions ? "移入废纸篓（%{0}）" : "一键卸载（%{0}）",
                                      arguments: [String(describing: showingExtensions ? model.selectedExtensions.count : model.selected.count)]),
                          systemImage: "trash")
                }
                .disabled(model.busy || model.scanning || (showingExtensions ? model.selectedExtensions.isEmpty : model.selected.isEmpty))
            }
            if showingExtensions {
                HStack(alignment: .top, spacing: 14) {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(ExtensionUninstallCategory.allCases) { category in
                                Button { selectedCategory = category } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: category.symbol)
                                            .font(.system(size: 19, weight: .medium))
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 26)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(L10n.text(category.title)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                            Text(categorySummary(category)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 2)
                                        Text(categoryItems(for: category).isEmpty ? "–" : CacheCleaner.formattedSize(categorySize(for: category)))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedCategory == category ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor),
                                                in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12)
                                        .stroke(selectedCategory == category ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(width: 260)
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(categoryItems) { item in
                                Toggle(isOn: Binding(
                                    get: { model.selectedExtensions.contains(item.id) },
                                    set: { if $0 { model.selectedExtensions.insert(item.id) } else { model.selectedExtensions.remove(item.id) } })) {
                                    HStack(spacing: 10) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path))
                                            .resizable().scaledToFit().frame(width: 32, height: 32)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                            Text(item.url.path).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }
                                        Spacer(minLength: 4)
                                        Text(CacheCleaner.formattedSize(item.size)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(9)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                }
                                .toggleStyle(.checkbox)
                                .disabled(model.busy)
                            }
                            if categoryItems.isEmpty && !model.scanning {
                                Text(L10n.text("此分类没有可卸载项目")).foregroundStyle(.secondary).padding(28)
                            }
                        }
                    }
                }.padding(4)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 16)], spacing: 16) {
                        ForEach(model.apps) { app in
                            VStack(spacing: 8) {
                                HStack {
                                    Spacer()
                                    Toggle(L10n.format("选择 %{0}", arguments: [String(describing: app.name)]), isOn: Binding(
                                        get: { model.selected.contains(app.id) },
                                        set: { if $0 { model.selected.insert(app.id) } else { model.selected.remove(app.id) } }))
                                        .toggleStyle(.checkbox).labelsHidden().disabled(model.busy)
                                }
                                Button { detail = app } label: {
                                    VStack(spacing: 8) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path))
                                            .resizable().scaledToFit().frame(width: 76, height: 76)
                                        Text(app.name).font(.system(size: 13, weight: .medium))
                                            .lineLimit(2).multilineTextAlignment(.center).frame(height: 36)
                                        Text(L10n.text(app.sizeIsCalculated ? CacheCleaner.formattedSize(app.size) : L10n.text("正在计算大小…"))).font(.caption).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity)
                                }.buttonStyle(.plain).accessibilityLabel(L10n.format("查看 %{0} 详情", arguments: [String(describing: app.name)]))
                            }
                            .padding(12)
                            .background(model.selected.contains(app.id) ? Color.accentColor.opacity(0.12) : Color(nsColor: .controlBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(model.selected.contains(app.id) ? Color.accentColor : Color.clear, lineWidth: 2))
                        }
                    }.padding(4)
                    if model.apps.isEmpty && !model.busy && !model.scanning { Text(L10n.text("未找到可卸载的应用")).foregroundStyle(.secondary).padding(40) }
                }
            }
            HStack { if model.busy || model.scanning { ProgressView().controlSize(.small) }; Text(L10n.text(model.status)).font(.caption).foregroundStyle(.secondary) }
            Text(L10n.text(showingExtensions
                ? "扩展卸载仅扫描当前用户目录；确认后所选项目会移入废纸篓。"
                : "点击应用查看详情，勾选多个应用后可一键卸载。应用及确认勾选的关联项会移入废纸篓。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18)
        .sheet(item: $detail) { app in
            let currentApp = model.apps.first { $0.id == app.id } ?? app
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 16) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().scaledToFit().frame(width: 80, height: 80)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(app.name).font(.title2)
                        Text(L10n.text(currentApp.sizeIsCalculated ? CacheCleaner.formattedSize(currentApp.size) : L10n.text("正在计算大小…"))).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Text(L10n.format("版本：%{0}", arguments: [String(describing: Bundle(url: app.url)?.infoDictionary?["CFBundleShortVersionString"] as? String ?? L10n.text("未知"))]))
                Text(L10n.format("应用标识：%{0}", arguments: [String(describing: app.bundleID.isEmpty ? L10n.text("未知") : app.bundleID)]))
                Text(L10n.format("位置：%{0}", arguments: [String(describing: app.url.path)])).textSelection(.enabled)
                HStack {
                    Button(L10n.text("在 Finder 中显示")) { NSWorkspace.shared.activateFileViewerSelecting([app.url]) }
                    Spacer()
                    Button(L10n.text("完成")) { detail = nil }.keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 500)
        }
    }

    private var categoryItems: [UninstallableExtension] {
        categoryItems(for: selectedCategory)
    }

    private func categoryItems(for category: ExtensionUninstallCategory) -> [UninstallableExtension] {
        model.extensionItems.filter { $0.category == category }
    }

    private func categorySize(for category: ExtensionUninstallCategory) -> Int64 {
        categoryItems(for: category).reduce(0) { $0 + $1.size }
    }

    private func categorySummary(_ category: ExtensionUninstallCategory) -> String {
        let count = categoryItems(for: category).count
        return count == 0 ? L10n.text("无项目") : L10n.format("%{0} 个项目", arguments: [String(count)])
    }
}

// Health checks are read-only; cache actions use the existing verified trash plan.
private final class MacHealthModel: ObservableObject {
    @Published var externalDisks: [MountedDiskUsage] = []
    @Published var hardware: HardwareSnapshot?
    @Published var inspection: [MachineInspectionItem] = []
    @Published var snapshot: SystemSnapshot?
    @Published var userFolders: [FolderUsage] = []
    @Published var applications: [InstalledApplication] = []
    @Published var startup: [StartupItem] = []
    @Published var caches: [CacheEntry] = []
    @Published var systemCacheEntries: [CacheEntry] = []
    @Published var systemCaches: (bytes: Int64, incomplete: Bool)?
    @Published var systemLibraryCaches: (bytes: Int64, incomplete: Bool)?
    @Published var systemStorage: (bytes: Int64, incomplete: Bool)?
    @Published var userLibraryStorage: (bytes: Int64, incomplete: Bool)?
    @Published var scanning = false
    @Published var phase = "准备检查"
    @Published var checkedAt: Date?
    var problems: [StartupItem] {
        startup.filter { item in
            ["无法解析", "不存在", "缺少", "未确认", "未读取"].contains { item.startupStatus.contains($0) }
        }
    }
    static func measure(_ root: URL, excludingPaths: Set<String> = []) -> (bytes: Int64, incomplete: Bool) {
        var incomplete = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), errorHandler: { _, _ in incomplete = true; return true }) else { return (0, true) }
        var bytes: Int64 = 0
        for case let url as URL in walker {
            if excludingPaths.contains(url.standardizedFileURL.path) { walker.skipDescendants(); continue }
            guard let values = try? url.resourceValues(forKeys: keys) else { incomplete = true; continue }
            if values.isSymbolicLink == true { walker.skipDescendants(); continue }
            if values.isRegularFile == true { bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0) }
        }
        return (bytes, incomplete)
    }

    private static let userFolderDirectories: [(String, FileManager.SearchPathDirectory)] = [
        ("桌面", .desktopDirectory), ("文稿", .documentDirectory), ("下载", .downloadsDirectory),
        ("影片", .moviesDirectory), ("音乐", .musicDirectory), ("图片", .picturesDirectory)
    ]

    private static func userFolders() -> [(name: String, url: URL)] {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        return userFolderDirectories.compactMap { definition in
            let (name, directory) = definition
            guard let url = FileManager.default.urls(for: directory, in: .userDomainMask).first else { return nil }
            let standardized = url.standardizedFileURL
            let values = try? standardized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard standardized.path.hasPrefix(home.path + "/"),
                  values?.isDirectory == true,
                  values?.isSymbolicLink != true else { return nil }
            return (name, standardized)
        }
    }

    static func scanUserFolders() -> [FolderUsage] {
        userFolders().map { folder in
            let result = measure(folder.url)
            return FolderUsage(name: folder.name, url: folder.url, bytes: result.bytes, incomplete: result.incomplete)
        }.sorted { $0.bytes > $1.bytes }
    }

    static func findLargeFiles(minimumSize: Int64 = 100 * 1024 * 1024) -> [LargeFileEntry] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
            .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .contentModificationDateKey
        ]
        var matches: [LargeFileEntry] = []
        for folder in userFolders() {
            guard let walker = FileManager.default.enumerator(
                at: folder.url,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }
            for case let fileURL as URL in walker {
                guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
                if values.isSymbolicLink == true || (values.isDirectory == true && values.isPackage == true) {
                    walker.skipDescendants()
                    continue
                }
                guard values.isRegularFile == true else { continue }
                let fileSizeValue = values.fileSize ?? 0
                let fileSize = Int64(fileSizeValue)
                let allocatedSize = Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? fileSizeValue)
                guard allocatedSize >= minimumSize else { continue }
                matches.append(LargeFileEntry(
                    url: fileURL.standardizedFileURL,
                    folderName: folder.name,
                    allocatedSize: allocatedSize,
                    fileSize: fileSize,
                    modifiedAt: values.contentModificationDate
                ))
            }
        }
        return matches.sorted { $0.allocatedSize > $1.allocatedSize }
    }
}

private struct MountedDiskUsage: Identifiable {
    let url: URL
    let name: String
    let total: Int64
    let available: Int64
    var id: String { url.path }
    var used: Int64 { max(0, total - available) }
    static func externalDisks() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeIsInternalKey, .volumeIsLocalKey]
        return (FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys), options: [.skipHiddenVolumes]) ?? []).compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.volumeIsInternal == false,
                  values.volumeIsLocal == true, let total = values.volumeTotalCapacity,
                  let available = values.volumeAvailableCapacity else { return nil }
            return Self(url: url, name: values.volumeName ?? url.lastPathComponent, total: Int64(total), available: Int64(available))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

private struct FolderUsage: Identifiable {
    let name: String
    let url: URL
    let bytes: Int64
    let incomplete: Bool
    var id: String { url.path }
}

private struct DiskUsageSegment: Identifiable {
    let id: String
    let title: String
    let bytes: Int64
    let color: Color
    let start: Double
    let end: Double
}

private struct LargeFileEntry: Identifiable {
    let url: URL
    let folderName: String
    let allocatedSize: Int64
    let fileSize: Int64
    let modifiedAt: Date?
    var id: String { url.path }
}

@MainActor
private final class HardwareBenchmarkModel: ObservableObject {
    @Published var running = false
    @Published var results: [HardwareBenchmark: [(String, String)]] = [:]
    @Published var messages: [HardwareBenchmark: String] = [:]
    private var task: Task<Void, Never>?
    private var hasStarted = false

    func startAllIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        running = true
        for kind in HardwareBenchmark.allCases {
            messages[kind] = "测试中…"
            results[kind] = nil
        }
        task = Task.detached(priority: .utility) { [weak self] in
            for kind in HardwareBenchmark.allCases {
                do {
                    let result = try kind.run()
                    await self?.finish(kind, result: result, message: "测试完成")
                } catch is CancellationError {
                    await self?.finish(kind, result: [], message: "测试已取消")
                    break
                } catch {
                    await self?.finish(kind, result: [], message: error.localizedDescription)
                }
            }
            await self?.finishAll()
        }
    }

    private func finish(_ kind: HardwareBenchmark, result: [(String, String)], message: String) {
        results[kind] = result
        messages[kind] = message
    }

    private func finishAll() {
        running = false
        task = nil
    }

    deinit { task?.cancel() }
}

private struct MacHealthView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @StateObject private var benchmarks = HardwareBenchmarkModel()
    @ObservedObject var model: MacHealthModel
    let scan: () -> Void
    let clean: ([CacheEntry]) -> Void
    @State private var selected = Set<URL>()
    @State private var showingCacheAnalysis = false
    @State private var largeFiles: [LargeFileEntry] = []
    @State private var selectedLargeFileIDs = Set<String>()
    @State private var searchingLargeFiles = false
    @State private var searchedLargeFiles = false
    @State private var largeFileOperationMessage: String?
    @State private var largeFilesWindowController: NSWindowController?
    private let folderColors: [Color] = [.blue, .orange, .green, .pink, .cyan, .indigo]
    private let columns = [GridItem(.adaptive(minimum: 360), spacing: 18, alignment: .top)]
    private func size(_ value: Int64) -> String { CacheCleaner.formattedSize(value) }
    private func folderName(_ name: String) -> String {
        guard L10n.isEnglish else { return name }
        switch name {
        case "桌面": return "Desktop"
        case "文稿": return "Documents"
        case "下载": return "Downloads"
        case "影片": return "Movies"
        case "音乐": return "Music"
        case "图片": return "Pictures"
        default: return name
        }
    }
    private var installedApplications: [InstalledApplication] {
        model.applications.filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }
    private var automaticInspection: [MachineInspectionItem] { model.inspection.filter { $0.id == "battery" } }
    private var selectedLargeFiles: [LargeFileEntry] { largeFiles.filter { selectedLargeFileIDs.contains($0.id) } }
    private var userCacheBytes: Int64 { model.caches.reduce(0) { $0 + max(0, $1.size) } }
    private var systemCacheBytes: Int64 { (model.systemCaches?.bytes ?? 0) + (model.systemLibraryCaches?.bytes ?? 0) }
    private var thermalReadings: [String] {
        (model.hardware?.temperature ?? "读取中…").components(separatedBy: " · ")
            .filter { $0.split(separator: " ").first.map(String.init) != L10n.text("电池") }
    }
    private var batteryTemperature: String? {
        model.hardware?.temperature.components(separatedBy: " · ").first {
            $0.split(separator: " ").first.map(String.init) == L10n.text("电池")
        }
    }
    private var fanRPMReadings: [String] {
        guard let fanSpeed = model.hardware?.fanSpeed else { return [L10n.text("读取中…")] }
        let expression = try? NSRegularExpression(pattern: "[0-9,]+\\s*RPM", options: [.caseInsensitive])
        let range = NSRange(fanSpeed.startIndex..., in: fanSpeed)
        let readings = expression?.matches(in: fanSpeed, range: range).compactMap {
            Range($0.range, in: fanSpeed).map { String(fanSpeed[$0]).replacingOccurrences(of: " ", with: "") }
        } ?? []
        return readings.isEmpty ? [L10n.text("转速不可用")] : readings
    }

    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("MAC HEALTH").font(.caption.weight(.semibold)).tracking(2).foregroundStyle(.secondary)
                        Text(L10n.text("让 Mac 保持好状态")).font(.system(size: 28, weight: .bold))
                    }
                    Spacer()
                    Button(action: scan) { Label(L10n.text(model.scanning ? L10n.text("检查中…") : L10n.text("重新检查")), systemImage: "arrow.clockwise") }
                        .buttonStyle(.borderedProminent).controlSize(.large).disabled(model.scanning)
                }
                if model.scanning {
                    VStack(alignment: .leading, spacing: 7) {
                        ProgressView().progressViewStyle(.linear)
                        Text(L10n.text(model.phase))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(L10n.text(model.phase))
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    summaryCard(model.hardware?.modelName ?? L10n.text("读取中…"), symbol: "laptopcomputer", color: .blue) {
                        Text(L10n.format("%{0} · %{1} 核 · %{2} 内存", arguments: [
                            String(describing: model.hardware?.chip ?? "—"),
                            String(describing: model.hardware?.coreCount ?? String(ProcessInfo.processInfo.activeProcessorCount)),
                            String(describing: model.hardware?.memory ?? size(Int64(ProcessInfo.processInfo.physicalMemory)))
                        ])).foregroundStyle(.secondary)
                        Text(ProcessInfo.processInfo.operatingSystemVersionString).font(.caption).foregroundStyle(.secondary)
                        HStack(spacing: 8) {
                            Label(L10n.text("序列号"), systemImage: "number")
                                .font(.caption).foregroundStyle(.secondary)
                            Spacer(minLength: 4)
                            if let serialNumber = model.hardware?.serialNumber,
                               let url = coverageURL(serialNumber: serialNumber) {
                                Link(serialNumber, destination: url)
                                    .font(.caption.monospaced()).lineLimit(1)
                            } else {
                                Text(model.hardware == nil ? L10n.text("读取中…") : L10n.text("暂不可读取"))
                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(["management", "sip"], id: \.self) { inspectionID in
                                if let item = model.inspection.first(where: { $0.id == inspectionID }) {
                                    Label(L10n.text(item.value), systemImage: inspectionSymbol(item.status))
                                        .font(.system(size: 12, weight: .medium))
                                        .foregroundStyle(inspectionColor(item.status))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    summaryCard(L10n.statusList("热压力 · " + ((model.snapshot?.thermalLevel ?? 0) == 0 ? "正常" : "异常")), symbol: "thermometer.medium", color: (model.snapshot?.thermalLevel ?? 0) == 0 ? .teal : .orange) {
                        VStack(alignment: .center, spacing: 7) {
                            ForEach(Array(thermalReadings.enumerated()), id: \.offset) { _, value in
                                Text(L10n.statusList(value)).font(.system(size: 14, weight: .regular)).monospacedDigit()
                                    .frame(maxWidth: .infinity, alignment: .center)
                            }
                        }
                        ForEach(Array(fanRPMReadings.enumerated()), id: \.offset) { _, rpm in
                            Label(rpm, systemImage: "fanblades")
                                .font(.system(size: 14, weight: .medium)).monospacedDigit()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    summaryCard("", symbol: nil, color: .purple) {
                        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "display").font(.system(size: 18)).foregroundStyle(.purple)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(screen.localizedName).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                                    if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                                        Text("\(CGDisplayPixelsWide(number.uint32Value)) × \(CGDisplayPixelsHigh(number.uint32Value))")
                                            .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    summaryCard("电池", symbol: "battery.100percent", color: .teal) {
                        ForEach(automaticInspection) { item in
                            Text(L10n.text(item.value))
                                .font(.system(size: 14, weight: .semibold)).foregroundStyle(inspectionColor(item.status))
                            ForEach(Array(item.detail.components(separatedBy: " · ").enumerated()), id: \.offset) { _, metric in
                                Text(L10n.text(metric))
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if let batteryTemperature {
                                Text(L10n.statusList(batteryTemperature))
                                    .font(.system(size: 13)).foregroundStyle(.secondary)
                            }
                        }
                        if automaticInspection.isEmpty {
                            Text(L10n.text("读取中…")).foregroundStyle(.secondary)
                        }
                    }
                }
                panel("硬件性能测试", symbol: "speedometer", color: .orange) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(HardwareBenchmark.allCases) { kind in
                            benchmarkSummary(kind)
                                .padding(14)
                                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    panel("磁盘空间", symbol: "internaldrive.fill", color: .purple,
                          headerTrailing: model.inspection.filter { $0.id == "storage" || $0.id == "filevault" }) {
                        if let s = model.snapshot, s.diskTotal > 0 {
                            let total = max(1, s.diskTotal)
                            let used = min(max(0, s.diskUsed), total)
                            let segments = diskUsageSegments(total: total, used: used)
                            HStack(spacing: 18) {
                                ZStack {
                                    Circle().stroke(.purple.opacity(0.10), lineWidth: 12)
                                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                                        Circle().trim(from: segment.start, to: segment.end)
                                            .stroke(segment.color, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                                            .rotationEffect(.degrees(-90))
                                    }
                                    Text(L10n.format("%{0}%\n已使用", arguments: [String(describing: Int(Double(used) / Double(total) * 100))])).font(.headline).multilineTextAlignment(.center)
                                }.frame(width: 108, height: 108)
                                VStack(alignment: .leading, spacing: 9) {
                                    Text(size(Int64(total - used))).font(.title2.weight(.semibold))
                                    Text(L10n.format("可用 / 共 %{0}", arguments: [String(describing: size(Int64(total)))] )).foregroundStyle(.secondary)
                                    Text(L10n.text(Double(total - used) / Double(total) < 0.1 ? L10n.text("空间偏低，建议检查大文件") : L10n.text("空间充足"))).foregroundStyle(Double(total - used) / Double(total) < 0.1 ? .orange : .teal)
                                }
                            }
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0), alignment: .leading), count: 3), alignment: .leading, spacing: 6) {
                                ForEach(segments) { segment in
                                    HStack(spacing: 4) {
                                        Circle().fill(segment.color).frame(width: 7, height: 7)
                                        Text(L10n.text(segment.title)).lineLimit(1)
                                        Spacer(minLength: 1)
                                        Text(size(segment.bytes)).monospacedDigit().lineLimit(1)
                                    }
                                    .font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                            }
                            Text(L10n.text("分项之和与磁盘已用总量一致；其他包含未分类文件、系统快照和文件系统开销。"))
                                .font(.system(size: 9)).foregroundStyle(.tertiary).lineLimit(2)
                        } else {
                            Text(L10n.text("磁盘容量尚未读取")).foregroundStyle(.secondary)
                        }
                        if !model.externalDisks.isEmpty {
                            Divider()
                            ScrollView(.vertical) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(model.externalDisks) { disk in
                                        externalDiskRow(disk)
                                    }
                                }
                            }.frame(maxHeight: 110)
                        }
                        Divider()
                        HStack {
                            Spacer()
                            Button(action: openLargeFilesWindow) {
                                Label(L10n.text("查找大文件"), systemImage: "doc.text.magnifyingglass")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.purple)
                            .disabled(searchingLargeFiles || model.scanning)
                        }
                    }
                    .frame(height: model.externalDisks.isEmpty ? 360 : 470, alignment: .topLeading)
                    panel("应用分析", symbol: "square.stack.3d.up.fill", color: .indigo,
                          headerAction: AnyView(
                            Button { _ = DashboardWindow.open(.uninstaller) } label: {
                                Label(L10n.text("管理已安装应用"), systemImage: "square.grid.2x2")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .tint(.indigo)
                          )) {
                        HStack(spacing: 12) {
                            Text(L10n.format("%{0} 个应用", arguments: [String(describing: installedApplications.count)]))
                                .font(.title2.weight(.semibold))
                            Text(L10n.format("占用 %{0} 空间", arguments: [String(describing: size(installedApplications.reduce(0) { $0 + $1.size }))]))
                                .foregroundStyle(.secondary)
                        }
                        ScrollView(.vertical) {
                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                                ForEach(installedApplications.sorted { $0.size > $1.size }) { app in
                                    VStack(spacing: 5) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 40, height: 40)
                                        Text(app.name).font(.caption).lineLimit(1)
                                        Text(size(app.size)).font(.caption2).foregroundStyle(.secondary)
                                    }.frame(maxWidth: .infinity).help("\(app.name) · \(app.url.path)")
                                }
                            }
                        }
                        .frame(maxHeight: .infinity)
                        .scrollIndicators(.visible)
                    }
                    .frame(height: 305, alignment: .topLeading)
                    panel("启动与配置", symbol: "gearshape.2.fill", color: .orange) {
                        Text(L10n.text(model.scanning ? L10n.text("正在检查配置…") : model.problems.isEmpty ? L10n.text("未发现配置异常") : L10n.format("%{0} 项需要核查", arguments: [String(describing: model.problems.count)]))).font(.title2.weight(.semibold))
                        Text(L10n.format("检查 %{0} 个 LaunchAgent / LaunchDaemon 的格式、程序路径与执行权限。运行状态未知。", arguments: [String(describing: model.startup.count)])).foregroundStyle(.secondary)
                        ForEach(model.problems.prefix(3)) { item in
                            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                                Label(item.label, systemImage: "exclamationmark.triangle.fill").font(.caption).lineLimit(1)
                            }.buttonStyle(.bordered).help(L10n.statusList(item.startupStatus))
                        }
                        Button(L10n.text("查看启动配置")) { _ = DashboardWindow.open(.launchItems) }.buttonStyle(.bordered)
                    }
                    panel("磁盘缓存", symbol: "externaldrive.badge.minus", color: .teal) {
                        Text(size(userCacheBytes + systemCacheBytes)).font(.title2.weight(.semibold))
                        HStack(spacing: 14) {
                            Label(L10n.format("用户缓存 %{0}", arguments: [size(userCacheBytes)]), systemImage: "person.fill")
                            Label(L10n.format("系统缓存 %{0}", arguments: [model.systemCaches.map { size($0.bytes + (model.systemLibraryCaches?.bytes ?? 0)) } ?? L10n.text("分析中…")]), systemImage: "gearshape.fill")
                        }
                        .font(.caption).foregroundStyle(.secondary)
                        Text(L10n.text("缓存分析包含用户缓存和 /Library/Caches。选择要清理的项目后，会逐项验证并移入废纸篓。"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Spacer()
                            Button(L10n.text("清理缓存")) { showingCacheAnalysis = true }
                                .buttonStyle(.borderedProminent).disabled(model.scanning)
                        }
                    }
                }
            }.padding(8)
        }
        .task { benchmarks.startAllIfNeeded() }
        .onChange(of: model.scanning) { _, scanning in if scanning { selected.removeAll() } }
        .sheet(isPresented: $showingCacheAnalysis) {
            CacheAnalysisSheet(
                userCaches: model.caches,
                systemCaches: model.systemCacheEntries,
                systemTotal: model.systemCaches?.bytes,
                systemIncomplete: model.systemCaches?.incomplete ?? false,
                selectedIDs: $selected,
                scanning: model.scanning,
                name: cacheName,
                size: size
            ) { entries in
                showingCacheAnalysis = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { clean(entries) }
            }
            .frame(minWidth: 640, minHeight: 520)
        }
    }

    private func cacheName(_ entry: CacheEntry) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.name) else { return entry.name }
        return FileManager.default.displayName(atPath: url.path)
    }
    private func externalDiskRow(_ disk: MountedDiskUsage) -> some View {
        let total = max(1, disk.total)
        let used = min(max(0, disk.used), total)
        let usedRatio = Double(used) / Double(total)
        let usedPercent = Int((usedRatio * 100).rounded())
        let availablePercent = 100 - usedPercent
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.fill").foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 2) {
                    Text(disk.name).font(.system(size: 12, weight: .semibold))
                    Text(L10n.format("已用 %{0} / 共 %{1} · 可用 %{2}", arguments: [size(disk.used), size(disk.total), size(disk.available)]))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.14))
                    Capsule().fill(.purple).frame(width: geometry.size.width * usedRatio)
                }
            }
            .frame(height: 6)
            .accessibilityLabel("\(L10n.text("已使用")) \(usedPercent)%, \(L10n.text("可用空间")) \(availablePercent)%")
            HStack {
                Text("\(L10n.text("已使用")) \(usedPercent)%").foregroundStyle(.purple)
                Spacer()
                Text("\(L10n.text("可用空间")) \(availablePercent)%").foregroundStyle(.secondary)
            }
            .font(.system(size: 10, weight: .medium))
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .help(disk.url.path)
    }
    private func diskUsageSegments(total: UInt64, used: UInt64) -> [DiskUsageSegment] {
        guard total > 0, used > 0 else { return [] }

        var categories: [(id: String, title: String, bytes: Int64, color: Color)] = model.userFolders.enumerated().map { index, folder in
            ("folder:\(folder.id)", folderName(folder.name), max(0, folder.bytes), folderColors[index % folderColors.count])
        }
        let applicationBytes = installedApplications.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let userLibraryBytes = model.userLibraryStorage?.bytes ?? 0
        let systemBytes = model.systemStorage?.bytes ?? 0
        if applicationBytes > 0 { categories.append(("applications", "应用占用", applicationBytes, .indigo)) }
        if userLibraryBytes > 0 { categories.append(("user-library", "用户资料库", userLibraryBytes, .cyan)) }
        if userCacheBytes > 0 { categories.append(("user-caches", "用户缓存", userCacheBytes, .mint)) }
        if systemCacheBytes > 0 { categories.append(("system-caches", "系统缓存", systemCacheBytes, .orange)) }
        if systemBytes > 0 { categories.append(("system", "macOS 系统占用", systemBytes, .purple)) }
        categories.removeAll { $0.bytes <= 0 }

        let targetBytes = Int64(min(used, UInt64(Int64.max)))
        let measuredBytes = categories.reduce(0.0) { $0 + Double($1.bytes) }
        let scale = measuredBytes > Double(targetBytes) && measuredBytes > 0
            ? Double(targetBytes) / measuredBytes
            : 1
        var normalized = categories.map { Int64((Double($0.bytes) * scale).rounded(.down)) }
        let normalizedTotal = normalized.reduce(Int64(0), +)
        if scale < 1, let last = normalized.indices.last {
            normalized[last] += max(0, targetBytes - normalizedTotal)
        }
        let knownBytes = normalized.reduce(Int64(0), +)
        let otherBytes = max(0, targetBytes - knownBytes)

        var cursor = 0.0
        var segments: [DiskUsageSegment] = []
        for (index, category) in categories.enumerated() {
            let bytes = normalized[index]
            guard bytes > 0 else { continue }
            let end = min(Double(used) / Double(total), cursor + Double(bytes) / Double(total))
            segments.append(DiskUsageSegment(id: category.id, title: category.title, bytes: bytes,
                                             color: category.color, start: cursor, end: end))
            cursor = end
        }
        if otherBytes > 0 {
            let end = min(Double(used) / Double(total), cursor + Double(otherBytes) / Double(total))
            segments.append(DiskUsageSegment(id: "other", title: "其他占用", bytes: otherBytes,
                                             color: .gray, start: cursor, end: end))
        }
        return segments
    }
    private func benchmarkSummary(_ kind: HardwareBenchmark) -> some View {
        let label: String
        switch kind {
        case .disk: label = "硬盘"
        case .memory: label = "内存"
        case .localAI: label = "本地 AI 估算"
        }
        let metrics = (benchmarks.results[kind] ?? []).compactMap { name, value -> (String, String)? in
            guard name != "校验值" else { return nil }
            let shortName: String
            switch name {
            case "顺序写入", "内存写入": shortName = "写"
            case "顺序读取": shortName = "读"
            case "CPU计算": shortName = "CPU 算力"
            case "GPU设备": shortName = "GPU"
            case "GPU计算": shortName = "GPU 算力"
            case "系统内存": shortName = "内存"
            case "4-bit模型": shortName = "4-bit"
            case "8-bit模型": shortName = "8-bit"
            case "FP16模型": shortName = "FP16"
            default: shortName = "复制"
            }
            return (shortName, benchmarkRate(value))
        }
        let aiMetrics = metrics.filter { $0.0 == "CPU 算力" || $0.0 == "GPU 算力" }
        let fp16Estimate = benchmarks.results[kind]?.first { $0.0 == "FP16模型" }?.1
        let heading: String
        if kind == .localAI, let fp16Estimate {
            heading = label + " · FP16 " + L10n.text(fp16Estimate)
        } else {
            heading = label
        }
        return VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text(heading), systemImage: kind.symbol)
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
                .lineLimit(1).minimumScaleFactor(0.8)
            if kind == .localAI {
                if aiMetrics.isEmpty {
                    if let message = benchmarks.messages[kind], message != "测试中…" {
                        Text(L10n.text(message)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    ForEach(Array(aiMetrics.enumerated()), id: \.offset) { _, metric in
                        HStack(spacing: 2) {
                            Text(L10n.text(metric.0)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(L10n.text(metric.1)).monospacedDigit().foregroundStyle(.primary)
                        }
                        .font(.caption2).lineLimit(1)
                    }
                }
            } else if metrics.isEmpty {
                if let message = benchmarks.messages[kind], message != "测试中…" {
                    Text(L10n.text(message)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                ForEach(Array(metrics.enumerated()), id: \.offset) { _, metric in
                    HStack(spacing: 2) {
                        Text(L10n.text(metric.0)).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        Text(L10n.text(metric.1)).monospacedDigit().foregroundStyle(.primary)
                    }
                    .font(.caption2).lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private func benchmarkRate(_ value: String) -> String {
        guard let megabytesPerSecond = Double(value.replacingOccurrences(of: " MB/s", with: "")) else { return value }
        if megabytesPerSecond >= 1_000 {
            return String(format: "%.1f GB/s", megabytesPerSecond / 1_000)
        }
        return String(format: "%.0f MB/s", megabytesPerSecond)
    }
    private func coverageURL(serialNumber: String) -> URL? {
        var components = URLComponents(string: "https://checkcoverage.apple.com/")
        components?.queryItems = [URLQueryItem(name: "locale", value: "zh_CN"), URLQueryItem(name: "sn", value: serialNumber)]
        return components?.url
    }
    private func openLargeFilesWindow() {
        if let window = largeFilesWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let rootView = LargeFilesWindowView(
            files: $largeFiles,
            selectedIDs: $selectedLargeFileIDs,
            searching: $searchingLargeFiles,
            searched: $searchedLargeFiles,
            operationMessage: $largeFileOperationMessage,
            scan: findLargeFiles,
            trash: trashSelectedLargeFiles,
            folderName: folderName,
            size: size
        )
        let controller = LargeFilesWindowController(rootView: rootView)
        largeFilesWindowController = controller
        controller.showWindow(nil)
        controller.window?.center()
        NSApp.activate(ignoringOtherApps: true)
        findLargeFiles()
    }

    private func findLargeFiles() {
        guard !searchingLargeFiles else { return }
        searchingLargeFiles = true
        searchedLargeFiles = false
        largeFileOperationMessage = nil
        DispatchQueue.global(qos: .utility).async {
            let results = MacHealthModel.findLargeFiles()
            DispatchQueue.main.async {
                self.largeFiles = results
                self.selectedLargeFileIDs.removeAll()
                self.searchingLargeFiles = false
                self.searchedLargeFiles = true
            }
        }
    }
    private func trashSelectedLargeFiles() {
        let candidates = selectedLargeFiles
        guard !candidates.isEmpty else { return }
        DispatchQueue.global(qos: .utility).async {
            var trashedIDs = Set<String>()
            var failures = 0
            for file in candidates {
                guard self.isUnchangedLargeFile(file) else { failures += 1; continue }
                do {
                    try FileManager.default.trashItem(at: file.url, resultingItemURL: nil)
                    trashedIDs.insert(file.id)
                } catch {
                    failures += 1
                }
            }
            let updatedFolders = MacHealthModel.scanUserFolders()
            DispatchQueue.main.async {
                self.largeFiles.removeAll { trashedIDs.contains($0.id) }
                self.selectedLargeFileIDs.subtract(trashedIDs)
                self.model.userFolders = updatedFolders
                self.largeFileOperationMessage = failures == 0
                    ? L10n.format("已将 %{0} 个文件移入废纸篓", arguments: [String(trashedIDs.count)])
                    : L10n.format("已移入 %{0} 个文件，另有 %{1} 个未处理", arguments: [String(trashedIDs.count), String(failures)])
            }
        }
    }
    private func isUnchangedLargeFile(_ file: LargeFileEntry) -> Bool {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL
        let url = file.url.standardizedFileURL
        guard url.path.hasPrefix(home.path + "/"),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              Int64(values.fileSize ?? 0) == file.fileSize,
              values.contentModificationDate == file.modifiedAt else { return false }
        var parent = url.deletingLastPathComponent()
        while parent.path != home.path {
            guard parent.path.hasPrefix(home.path + "/"),
                  let parentValues = try? parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  parentValues.isDirectory == true,
                  parentValues.isSymbolicLink != true else { return false }
            parent.deleteLastPathComponent()
        }
        return true
    }
    private func metric(_ title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(L10n.text(title), systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text(value)).font(.headline)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }
    private func inspectionSymbol(_ status: MachineInspectionStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .attention: return "exclamationmark.triangle.fill"
        case .informational: return "info.circle.fill"
        case .unavailable: return "questionmark.circle"
        }
    }
    private func inspectionColor(_ status: MachineInspectionStatus) -> Color {
        switch status {
        case .passed: return .teal
        case .attention: return .orange
        case .informational, .unavailable: return .secondary
        }
    }
    private func summaryCard<Content: View>(_ title: String, symbol: String?, color: Color, @ViewBuilder content: @escaping () -> Content) -> some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 12) {
                if !title.isEmpty {
                    HStack(spacing: 8) {
                        if let symbol {
                            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(color)
                                .frame(width: 30, height: 30).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
                        }
                        Text(L10n.text(title)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                    }
                }
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 10) { content() }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(14)
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.08)))
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
    }

    private func panel<Content: View>(_ title: String, symbol: String, color: Color,
                                      headerTrailing: [MachineInspectionItem] = [],
                                      headerAction: AnyView? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold)).foregroundStyle(color)
                    .frame(width: 38, height: 38).background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                Text(L10n.text(title)).font(.headline)
                ForEach(headerTrailing) { item in
                    Label(L10n.text(item.value), systemImage: inspectionSymbol(item.status))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(inspectionColor(item.status))
                        .lineLimit(1)
                        .help(L10n.text(item.detail))
                }
                Spacer()
                if let headerAction { headerAction }
            }
            content()
        }.padding(20).frame(minWidth: 0, maxWidth: .infinity, minHeight: 180, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.primary.opacity(0.06)))
    }
}

/// Restores the original Mac Health experience inside the current module shell.
struct LegacyMacHealthPage: View {
    @StateObject private var controller = LegacyMacHealthController()

    var body: some View {
        MacHealthView(model: controller.model, scan: controller.scan, clean: controller.clean)
            .onAppear {
                controller.refreshVolumes()
                if controller.model.checkedAt == nil { controller.scan() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in controller.refreshVolumes() }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in controller.refreshVolumes() }
    }
}

private final class LegacyMacHealthController: ObservableObject {
    let model = MacHealthModel()
    private var cacheEntries: [CacheEntry] = []
    private var scanGeneration = 0
    private var scanInProgress = false

    func refreshVolumes() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let disks = MountedDiskUsage.externalDisks()
            DispatchQueue.main.async { self?.model.externalDisks = disks }
        }
    }

    func scan() {
        guard !scanInProgress else { return }
        scanGeneration += 1
        let generation = scanGeneration
        scanInProgress = true
        model.scanning = true
        model.phase = "正在读取硬件与磁盘…"
        cacheEntries = []
        model.caches = []

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let hardware = HardwareSnapshot.read()
            let snapshot = SystemMonitor().sample()
            let externalDisks = MountedDiskUsage.externalDisks()
            let inspection = MachineInspection.read()
            let userFolders = MacHealthModel.scanUserFolders()
            DispatchQueue.main.async {
                guard generation == self.scanGeneration else { return }
                self.model.hardware = hardware
                self.model.snapshot = snapshot
                self.model.externalDisks = externalDisks
                self.model.inspection = inspection
                self.model.userFolders = userFolders
                self.model.phase = "正在分析应用与启动配置…"
            }

            let applications = ApplicationUninstaller.scan()
            let startup = StartupItemInspector.scan()
            let systemCaches = MacHealthModel.measure(URL(fileURLWithPath: "/Library/Caches"))
            let systemLibraryCachePath = URL(fileURLWithPath: "/System/Library/Caches", isDirectory: true)
            let systemLibraryCaches = MacHealthModel.measure(systemLibraryCachePath)
            let systemLibraryPath = URL(fileURLWithPath: "/System/Library", isDirectory: true)
            let systemLibrary = MacHealthModel.measure(systemLibraryPath, excludingPaths: [systemLibraryCachePath.path])
            let systemApplications = MacHealthModel.measure(URL(fileURLWithPath: "/System/Applications", isDirectory: true))
            let systemStorage = (bytes: systemLibrary.bytes + systemApplications.bytes,
                                 incomplete: systemLibrary.incomplete || systemApplications.incomplete)
            let userLibraryPath = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library", isDirectory: true)
            let userLibraryStorage = MacHealthModel.measure(
                userLibraryPath,
                excludingPaths: [userLibraryPath.appendingPathComponent("Caches", isDirectory: true).path]
            )
            var systemCacheEntries: [CacheEntry] = []
            CacheCleaner.scanBatches(isSystem: true) { batch, _ in systemCacheEntries.append(contentsOf: batch) }
            DispatchQueue.main.async {
                guard generation == self.scanGeneration else { return }
                self.model.applications = applications
                self.model.startup = startup
                self.model.systemCaches = systemCaches
                self.model.systemLibraryCaches = systemLibraryCaches
                self.model.systemStorage = systemStorage
                self.model.userLibraryStorage = userLibraryStorage
                self.model.systemCacheEntries = systemCacheEntries.sorted { $0.size > $1.size }
                self.model.phase = "正在分析用户缓存…"
            }
            CacheCleaner.scanBatches { batch, isComplete in
                DispatchQueue.main.async {
                    guard generation == self.scanGeneration else { return }
                    self.cacheEntries.append(contentsOf: batch)
                    self.cacheEntries.sort { $0.size > $1.size }
                    self.model.caches = self.cacheEntries
                    if isComplete {
                        self.scanInProgress = false
                        self.model.scanning = false
                        self.model.checkedAt = Date()
                        self.model.phase = "检查完成 · 基于当前可访问的目录"
                    }
                }
            }
        }
    }

    func clean(_ entries: [CacheEntry]) {
        guard let target = NSApp.keyWindow ?? NSApp.mainWindow else { return }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let plan = CacheCleaner.prepare(entries)
            DispatchQueue.main.async {
                guard let self, target.isVisible else { return }
                let alert = NSAlert()
                alert.messageText = L10n.text("将所选缓存内容移入废纸篓？")
                alert.informativeText = L10n.format(
                    "共 %{0} 个内容项，无法验证 %{1} 项。缓存目录将保留；建议先退出对应应用。清理前会再次验证路径和文件身份。可从废纸篓恢复。",
                    arguments: [String(plan.items.count), String(plan.rejected.count)]
                )
                let listing = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 180))
                listing.isEditable = false
                listing.font = .systemFont(ofSize: 11)
                listing.string = (plan.items.map { $0.url.path }
                    + plan.rejected.map { L10n.text("不可处理：") + $0.url.path }).joined(separator: "\n")
                let scroll = NSScrollView(frame: listing.frame)
                scroll.documentView = listing
                scroll.hasVerticalScroller = true
                alert.accessoryView = scroll
                alert.addButton(withTitle: L10n.text("取消"))
                alert.addButton(withTitle: L10n.text("移入废纸篓"))
                alert.beginSheetModal(for: target) { response in
                    guard response == .alertSecondButtonReturn else { return }
                    DispatchQueue.global(qos: .utility).async {
                        let results = plan.execute()
                        DispatchQueue.main.async {
                            self.scan()
                            let resultAlert = NSAlert()
                            resultAlert.messageText = L10n.text("缓存清理结果")
                            resultAlert.informativeText = FileOperationPlan.summary(results)
                            resultAlert.addButton(withTitle: L10n.text("好"))
                            resultAlert.beginSheetModal(for: target) { _ in }
                        }
                    }
                }
            }
        }
    }
}

private struct CacheAnalysisSheet: View {
    @Environment(\.dismiss) private var dismiss
    let userCaches: [CacheEntry]
    let systemCaches: [CacheEntry]
    let systemTotal: Int64?
    let systemIncomplete: Bool
    @Binding var selectedIDs: Set<URL>
    let scanning: Bool
    let name: (CacheEntry) -> String
    let size: (Int64) -> String
    let onClean: ([CacheEntry]) -> Void

    private var allEntries: [CacheEntry] { userCaches + systemCaches }
    private var selectedEntries: [CacheEntry] { allEntries.filter { selectedIDs.contains($0.id) } }
    private var selectedSize: Int64 { selectedEntries.reduce(0) { $0 + $1.size } }
    private var allSelected: Bool { !allEntries.isEmpty && allEntries.allSatisfy { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(L10n.text("缓存空间分析")).font(.title2.weight(.semibold))
                    Text(L10n.text("选择要清理的用户缓存或系统缓存目录；清理前会列出具体内容并再次验证。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L10n.text(allSelected ? "取消全选" : "全选")) {
                    if allSelected { selectedIDs.subtract(allEntries.map(\.id)) }
                    else { selectedIDs.formUnion(allEntries.map(\.id)) }
                }
                .disabled(allEntries.isEmpty || scanning)
            }
            HStack(spacing: 12) {
                cacheSummary(title: "用户缓存", value: size(userCaches.reduce(0) { $0 + $1.size }), count: userCaches.count, color: .teal)
                cacheSummary(title: "系统缓存", value: size(systemTotal ?? systemCaches.reduce(0) { $0 + $1.size }), count: systemCaches.count, color: .orange)
                cacheSummary(title: "所选项目", value: size(selectedSize), count: selectedEntries.count, color: .purple)
            }
            if systemIncomplete {
                Label(L10n.text("部分系统缓存不可读取，显示的系统占用可能不完整。"), systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(L10n.text("系统缓存扫描范围为 /Library/Caches；/System 与 /private/var 由 macOS 管理，不纳入清理。"))
                .font(.caption).foregroundStyle(.secondary)
            if scanning {
                ProgressView(L10n.text("正在分析缓存…"))
            }
            if allEntries.isEmpty && !scanning {
                ContentUnavailableView(L10n.text("没有可供清理的缓存目录"), systemImage: "externaldrive.badge.checkmark")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        cacheSection("用户缓存", path: "~/Library/Caches", entries: userCaches)
                        cacheSection("系统缓存", path: "/Library/Caches", entries: systemCaches)
                    }
                }
                .frame(minHeight: 220)
            }
            Text(L10n.text("系统目录中的受保护项目可能无法移入废纸篓；无法处理的项目会保留并显示在结果中。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button(L10n.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(L10n.format("审核并清理（%{0}）", arguments: [String(selectedEntries.count)])) {
                    let entries = selectedEntries
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { onClean(entries) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedEntries.isEmpty || scanning)
            }
        }
        .padding(22)
    }

    private func cacheSummary(title: String, value: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text(title)).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            Text(L10n.format("%{0} 个目录", arguments: [String(count)]))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func cacheSection(_ title: String, path: String, entries: [CacheEntry]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(L10n.text(title)).font(.headline)
                Text(path).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(L10n.format("%{0} 个目录", arguments: [String(entries.count)]))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if entries.isEmpty {
                Text(L10n.text(scanning ? "正在分析缓存…" : "没有可读取的缓存目录"))
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(entries) { entry in
                    Button {
                        if selectedIDs.contains(entry.id) { selectedIDs.remove(entry.id) }
                        else { selectedIDs.insert(entry.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedIDs.contains(entry.id) ? .teal : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(name(entry)).font(.body.weight(.medium)).lineLimit(1)
                                Text(entry.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 10)
                            Text(size(entry.size)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .background(selectedIDs.contains(entry.id) ? Color.teal.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .disabled(scanning)
                    .help(entry.url.path)
                }
            }
        }
    }
}

private final class LargeFilesWindowController: NSWindowController {
    init(rootView: LargeFilesWindowView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 580),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = L10n.text("查找大文件")
        window.minSize = NSSize(width: 560, height: 400)
        window.appearance = DashboardWindow.preferredAppearance
        window.contentView = NSHostingView(rootView: rootView.preferredColorScheme(DashboardWindow.preferredColorScheme))
        super.init(window: window)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance),
                                              name: .appearanceModeChanged, object: nil)
    }

    @objc private func refreshAppearance() {
        window?.appearance = DashboardWindow.preferredAppearance
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct LargeFilesWindowView: View {
    @Binding var files: [LargeFileEntry]
    @Binding var selectedIDs: Set<String>
    @Binding var searching: Bool
    @Binding var searched: Bool
    @Binding var operationMessage: String?
    let scan: () -> Void
    let trash: () -> Void
    let folderName: (String) -> String
    let size: (Int64) -> String
    @State private var confirmingTrash = false
    @State private var preferredScheme = DashboardWindow.preferredColorScheme

    private var selectedFiles: [LargeFileEntry] { files.filter { selectedIDs.contains($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.text("查找大文件")).font(.title2.weight(.semibold))
                    Text(L10n.text("扫描桌面、文稿、下载、影片、音乐和图片目录中的 100 MB 以上文件。"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: scan) {
                    Label(L10n.text(searching ? "查找中…" : "重新扫描"), systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(searching)
            }
            Divider()
            HStack {
                Text(searched
                     ? L10n.format("找到 %{0} 个大文件（≥ %{1}）", arguments: [String(files.count), size(100 * 1024 * 1024)])
                     : L10n.text("准备扫描常用文件夹"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if searching { ProgressView().controlSize(.small) }
                if !files.isEmpty {
                    Button(L10n.text(selectedIDs.count == files.count ? "取消全选" : "全选")) {
                        if selectedIDs.count == files.count { selectedIDs.removeAll() }
                        else { selectedIDs = Set(files.map(\.id)) }
                    }
                    .buttonStyle(.borderless)
                }
            }
            if searching && files.isEmpty {
                Spacer()
                ProgressView(L10n.text("正在扫描文件…"))
                    .frame(maxWidth: .infinity)
                Spacer()
            } else if searched && files.isEmpty {
                Spacer()
                ContentUnavailableView(L10n.text("未找到 100 MB 以上的大文件"), systemImage: "doc.text.magnifyingglass")
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(files) { file in
                    Button {
                        if selectedIDs.contains(file.id) { selectedIDs.remove(file.id) }
                        else { selectedIDs.insert(file.id) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(file.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3).foregroundStyle(selectedIDs.contains(file.id) ? .teal : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(file.url.lastPathComponent).font(.body.weight(.medium)).lineLimit(1)
                                Text("\(folderName(file.folderName)) · \(file.url.deletingLastPathComponent().path)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 12)
                            Text(size(file.allocatedSize)).font(.body.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(file.url.path)
                }
            }
            if let operationMessage {
                Text(L10n.text(operationMessage)).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button(L10n.text("在 Finder 中显示")) {
                    NSWorkspace.shared.activateFileViewerSelecting(selectedFiles.map(\.url))
                }
                .buttonStyle(.bordered)
                .disabled(selectedFiles.isEmpty)
                Spacer()
                Button(L10n.format("移入废纸篓（%{0}）", arguments: [String(selectedFiles.count)])) {
                    confirmingTrash = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFiles.isEmpty || searching)
            }
        }
        .padding(22)
        .frame(minWidth: 560, minHeight: 400)
        .confirmationDialog(L10n.text("将所选大文件移入废纸篓？"), isPresented: $confirmingTrash, titleVisibility: .visible) {
            Button(L10n.text("移入废纸篓"), role: .destructive, action: trash)
            Button(L10n.text("取消"), role: .cancel) {}
        } message: {
            Text(L10n.format("将 %{0} 个所选文件移入废纸篓，可从废纸篓恢复。", arguments: [String(selectedFiles.count)]))
        }
        .onReceive(NotificationCenter.default.publisher(for: .appearanceModeChanged)) { _ in
            preferredScheme = DashboardWindow.preferredColorScheme
        }
        .preferredColorScheme(preferredScheme)
    }
}

/// Draw the rounded surface itself so the compositor cannot leave a rectangular material edge.
private final class QuickActionSurface: NSView {
    var focused = false { didSet { needsDisplay = true } }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 16, dy: 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 38, yRadius: 38)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(focused ? 0.30 : 0.12)
        shadow.shadowBlurRadius = focused ? 14 : 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSGraphicsContext.restoreGraphicsState()
        if focused {
            NSColor.controlAccentColor.withAlphaComponent(0.65).setStroke()
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 37, yRadius: 37)
            outline.lineWidth = 1.5
            outline.stroke()
        }
    }
}

private final class QuickActionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class QuickActionTableView: NSTableView {
    override func rowView(atRow row: Int, makeIfNecessary: Bool) -> NSTableRowView? {
        if let existing = super.rowView(atRow: row, makeIfNecessary: false) { return existing }
        guard makeIfNecessary else { return nil }
        return QuickActionRowView()
    }
}

private final class QuickActionRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        let selection = bounds.insetBy(dx: 2, dy: 2)
        let highlight = NSBezierPath(roundedRect: selection, xRadius: 14, yRadius: 14)
        NSColor.controlAccentColor.withAlphaComponent(0.13).setFill()
        highlight.fill()
    }
}

final class QuickActionWindowController: NSWindowController, NSTextFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    private let surface = QuickActionSurface()
    private let search = NSTextField()
    private let searchIcon = NSImageView()
    private let table = QuickActionTableView()
    private let scroll = NSScrollView()
    private let separator = NSBox()
    private let actions: [(String, String, DashboardWindow.Module)] = [
        ("搜索应用与文件", "search apps files", .search), ("剪贴板历史", "clipboard history", .clipboard),
        ("安全活动", "security files audit", .files), ("进程管理", "process", .processes),
        ("网络活动", "network", .network), ("网络诊断", "speed dns ping route 网络测速", .networkDiagnostics), ("录屏工具", "screen recording", .screenRecorder), ("应用日志", "logs", .logs),
        ("系统健康检查", "cache clean", .cacheCleaner), ("应用卸载", "uninstall", .uninstaller),
        ("启动项检查", "startup", .launchItems), ("设置", "settings preferences", .preferences)
    ]
    private enum Target { case item(SearchResult), operation(DashboardWindow.Module), website(URL), command(String), diskAccess, status }
    private struct Entry { let id: String; let title: String; let detail: String; let symbol: String; var image: NSImage? = nil; let target: Target }
    private var filtered: [Entry] = []
    private var localItems: [SearchResult] = []
    private let engine: QuickSearch
    private var activeQuery = ""

    init(engine: QuickSearch = .shared) {
        self.engine = engine
        let panel = QuickActionPanel(contentRect: NSRect(x: 0, y: 0, width: 652, height: 108),
            styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = L10n.text("快捷操作")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.alphaValue = 0.95
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: L10n.changed, object: nil)
        panel.delegate = self
        let root = surface
        panel.contentView = root
        search.placeholderString = L10n.text("搜应用/文件 · >命令在终端运行 · 网址在浏览器打开")
        search.font = .systemFont(ofSize: 16, weight: .regular)
        search.isBordered = false
        search.isBezeled = false
        search.drawsBackground = false
        search.focusRingType = .none
        search.delegate = self
        let icon = searchIcon
        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.text("搜索"))
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 24, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(icon)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 54
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(executeSelection)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        scroll.contentView.drawsBackground = false
        scroll.isHidden = true
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.isHidden = true
        root.addSubview(separator)
        for view in [search, scroll] { view.translatesAutoresizingMaskIntoConstraints = false; root.addSubview(view) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            icon.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            search.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 82),
            search.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
            // NSTextField aligns its text near the top of an oversized frame.
            // Use its natural text height and center that frame with the icon.
            search.centerYAnchor.constraint(equalTo: root.topAnchor, constant: 54),
            search.heightAnchor.constraint(equalToConstant: search.intrinsicContentSize.height),
            separator.topAnchor.constraint(equalTo: root.topAnchor, constant: 83),
            separator.heightAnchor.constraint(equalToConstant: 1),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -36),
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 86),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 40),
            scroll.trailingAnchor.constraint(equalTo: search.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -22)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func refreshLanguage() { window?.title = L10n.text("快捷操作"); search.placeholderString = L10n.text("搜应用/文件 · >命令在终端运行 · 网址在浏览器打开"); searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: L10n.text("搜索")); reload() }
    func prepare() { search.stringValue = ""; engine.warmUp(); reload(); window?.center() }
    func windowDidBecomeKey(_ notification: Notification) { surface.focused = true }
    func windowDidResignKey(_ notification: Notification) { surface.focused = false; engine.cancel(); window?.orderOut(nil) }
    func focusSearch() {
        if window?.makeFirstResponder(search) == true { surface.focused = true }
    }
    private func reload() {
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = query
        engine.cancel()
        localItems = []
        switch LauncherInput.parse(query) {
        case .empty: updateRows([])
        case .website(let url):
            updateRows([Entry(id: url.absoluteString, title: "打开网页", detail: url.absoluteString, symbol: "globe", target: .website(url))])
        case .command(let command):
            updateRows([Entry(id: "terminal", title: "在终端执行", detail: command, symbol: "terminal", target: .command(command))])
        case .search(let term):
            engine.search(term) { [weak self] results in
                guard let self, self.activeQuery == term else { return }
                self.localItems = results
                self.rebuildSearchRows(term)
            }
            rebuildSearchRows(term)
        }
    }
    private func rebuildSearchRows(_ term: String) {
        var items = localItems
        if !engine.requiresFullDiskAccess, term.hasPrefix("/") || term.hasPrefix("~/") {
            let path = (term as NSString).expandingTildeInPath
            if FileManager.default.fileExists(atPath: path), !items.contains(where: { $0.path == path }) {
                items.append(SearchResult.item(at: URL(fileURLWithPath: path)))
            }
        }
        let recent = UserDefaults.standard.stringArray(forKey: "launcher.recentItems") ?? []
        items = SearchResult.ordered(items, matching: term, recentPaths: recent)
        var rows = items.map { item in
            Entry(id: item.path, title: item.title, detail: item.typeLabel + " · " + item.path,
                  symbol: "", image: item.icon, target: .item(item))
        }
        let normalized = SearchFields.normalize(term)
        let matchingActions = actions.filter { (L10n.text($0.0) + " " + $0.0 + " " + $0.1).localizedCaseInsensitiveContains(term) }.sorted {
            let left = SearchFields($0.0).score(normalized) ?? Int.max
            let right = SearchFields($1.0).score(normalized) ?? Int.max
            if left != right { return left < right }
            return $0.0.localizedCaseInsensitiveCompare($1.0) == .orderedAscending
        }
        rows += matchingActions.map {
            Entry(id: "operation:" + $0.2.rawValue, title: $0.0, detail: "快捷操作", symbol: "bolt", target: .operation($0.2))
        }
        rows = Array(rows.prefix(30))
        if rows.isEmpty, !engine.isSearching, let command = LauncherInput.inferredCommand(term) {
            rows.append(Entry(id: "terminal:" + command, title: L10n.format("在终端执行 %{0}", arguments: [command]), detail: L10n.format("按回车运行；带参数时可输入 > %{0} 参数", arguments: [command]), symbol: "terminal", target: .command(command)))
        }
        if engine.requiresFullDiskAccess {
            rows.append(Entry(id: "permission", title: "当前程序的文件访问被系统拦截", detail: SearchDiskAccess.permissionDetail, symbol: "lock", target: .diskAccess))
        } else if rows.isEmpty {
            rows.append(Entry(id: "status", title: engine.isSearching ? "正在搜索文件、文件夹与应用…" : "没有找到匹配结果", detail: "未找到时可输入完整路径；网址直接打开，> 命令在终端执行", symbol: "magnifyingglass", target: .status))
        }
        updateRows(rows)
    }
    private func updateRows(_ entries: [Entry]) {
        let selectedID = filtered.indices.contains(table.selectedRow) ? filtered[table.selectedRow].id : nil
        filtered = entries
        scroll.isHidden = filtered.isEmpty
        separator.isHidden = filtered.isEmpty
        if let window {
            let height: CGFloat = filtered.isEmpty ? 108 : 118 + CGFloat(min(filtered.count, 6)) * table.rowHeight
            var frame = window.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            window.setFrame(frame, display: true)
        }
        table.reloadData()
        if !filtered.isEmpty {
            let row = selectedID.flatMap { id in filtered.firstIndex(where: { $0.id == id }) } ?? 0
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }
    func controlTextDidChange(_ obj: Notification) { reload() }
    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = filtered[row]
        let cell = NSTableCellView()
        let icon = NSImageView()
        icon.image = entry.image ?? NSImage(systemSymbolName: entry.symbol, accessibilityDescription: L10n.text(entry.title))
        icon.imageScaling = .scaleProportionallyDown
        if entry.image == nil { icon.contentTintColor = .secondaryLabelColor }
        let title = NSTextField(labelWithString: { if case .item = entry.target { return entry.title }; return L10n.text(entry.title) }())
        title.alignment = .left
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.lineBreakMode = .byTruncatingTail
        let detail = NSTextField(labelWithString: { if case .item(let item) = entry.target { return L10n.text(item.typeLabel) + " · " + item.path }; if case .command = entry.target { return entry.detail }; return L10n.text(entry.detail) }())
        detail.alignment = .left
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        for view in [icon, title, detail] { view.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(view) }
        cell.textField = title
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24), icon.heightAnchor.constraint(equalToConstant: 24),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.topAnchor.constraint(equalTo: cell.topAnchor, constant: 7),
            title.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            detail.trailingAnchor.constraint(equalTo: title.trailingAnchor)
        ])
        return cell
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)): executeSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
            guard !filtered.isEmpty else { return true }
            let delta = selector == #selector(NSResponder.moveDown(_:)) ? 1 : -1
            let row = max(0, min(filtered.count - 1, table.selectedRow + delta))
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
            return true
        default: return false
        }
    }
    @objc private func executeSelection() {
        guard filtered.indices.contains(table.selectedRow) else { return }
        let entry = filtered[table.selectedRow]
        if case .status = entry.target { return }
        if case .command = entry.target {} else {
            var recent = UserDefaults.standard.stringArray(forKey: "launcher.recentItems") ?? []
            recent.removeAll { $0 == entry.id }; recent.insert(entry.id, at: 0)
            UserDefaults.standard.set(Array(recent.prefix(50)), forKey: "launcher.recentItems")
        }
        engine.cancel()
        switch entry.target {
        case .item(let item):
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                close()
            } else if NSWorkspace.shared.open(URL(fileURLWithPath: item.path)) { close() }
            else { showError("无法打开", detail: item.path) }
        case .website(let url):
            if NSWorkspace.shared.open(url) { close() }
            else { showError("无法打开网页", detail: url.absoluteString) }
        case .command(let command):
            LauncherTerminal.open(command) { [weak self] error in
                if let error { self?.showError("终端启动失败", detail: error.localizedDescription) }
                else { self?.close() }
            }
        case .operation(let module):
            close()
            if module == .preferences { DashboardWindow.openPreferences() }
            else if module == .search { DashboardWindow.openCommandPalette() }
            else { _ = DashboardWindow.open(module) }
        case .diskAccess: close(); SearchDiskAccess.openSettings()
        case .status: break
        }
    }
    private func showError(_ title: String, detail: String) {
        updateRows([Entry(id: "error", title: title, detail: detail, symbol: "exclamationmark.triangle", target: .status)])
    }
}

// MARK: - Industrial home surfaces
private struct IndustrialGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for x in stride(from: CGFloat(0), through: rect.width, by: 10) {
            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: rect.height))
        }
        for y in stride(from: CGFloat(0), through: rect.height, by: 10) {
            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: rect.width, y: y))
        }
        return path
    }
}

private struct IndustrialShortcutFace: View {
    let title: String
    let symbol: String
    let tint: Color
    let scale: CGFloat
    let dockEnabled: Bool?
    var body: some View {
        VStack(spacing: 8 * scale) {
            Image(systemName: symbol)
                .font(.system(size: 30 * scale, weight: .regular))
                .foregroundStyle(tint)
                .frame(width: 40 * scale, height: 40 * scale)
                .overlay(alignment: .bottomTrailing) {
                    if let dockEnabled {
                        Circle().fill(dockEnabled ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                            .overlay(Circle().stroke(Color(nsColor: .controlBackgroundColor), lineWidth: 2))
                            .offset(x: 3, y: 2).accessibilityHidden(true)
                    }
                }
            Text(title).font(.system(size: 12 * scale, weight: .medium))
                .foregroundStyle(.primary).lineLimit(2).multilineTextAlignment(.center)
                .frame(maxWidth: .infinity).frame(height: 28 * scale, alignment: .top)
        }
        .padding(.top, 10 * scale)
        .frame(maxWidth: .infinity).frame(height: 94 * scale, alignment: .top)
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}
