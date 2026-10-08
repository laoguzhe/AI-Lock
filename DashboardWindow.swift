import AppKit
import SwiftUI
import UserNotifications
import Carbon.HIToolbox

private let ink = NSColor.labelColor
private let muted = NSColor.secondaryLabelColor
private let canvas = NSColor.windowBackgroundColor
private let cardColor = NSColor.controlBackgroundColor
private let lime = NSColor(calibratedRed: 0.71, green: 0.96, blue: 0.35, alpha: 1)
private let panelColor = NSColor.clear

final class DashboardWindow: NSWindowController, NSMenuDelegate {
    enum Module: String {
        case files = "文件活动", processes = "进程管理", network = "网络活动", logs = "系统日志", clipboard = "剪贴板历史", settings = "监控预警", preferences = "设置", dockLock = "DockLock", dockLockSettings = "DockLock 设置", search = "快速文件搜索", cacheCleaner = "系统健康检查", uninstaller = "应用卸载", launchItems = "启动项检查", launcher = "快捷操作"
    }

    static var dockLockEnabled: Bool { lockController?.enabled ?? (UserDefaults.standard.object(forKey: "dockLock.enabled") as? Bool ?? true) }
    static func toggleDockLock() -> Bool { lockController?.toggleEnabled() ?? false }
    static var dockLockTargetSetting: String { lockController?.targetSetting ?? "builtin" }
    static var dockLockScreens: [DockLock.ScreenChoice] { lockController?.screenChoices ?? [] }
    static func setDockLockTarget(_ value: String) { lockController?.setTarget(value) }
    static func toggleDisplayPrivacy(_ id: CGDirectDisplayID) { DisplayPrivacyManager.shared.toggle(id) }
    static var coveredDisplays: Set<CGDirectDisplayID> { DisplayPrivacyManager.shared.coveredIDs }
    private static weak var lockController: DockLock?
    private static var moduleWindows: [Module: DashboardWindow] = [:]
    private static var preferencesWindow: PreferencesWindowController?
    private var moduleRoot: NSView?
    private let logStore = SystemLogStore()
    private var logEntries: [SystemLogEntry] = []
    private var logPaused = false
    private var logLoadGeneration = 0
    private var networkEntries: [NetworkConnection] = []
    private var previousConnectionIDs = Set<String>()
    private var connectionEvents: [ConnectionEvent] = []
    private var cacheEntries: [CacheEntry] = []
    private weak var cacheTable: NSTableView?
    private weak var cacheStatus: NSTextField?
    private var cacheDataSource: CacheTableDataSource?
    private var cacheScanGeneration = 0
    private var cacheScanInProgress = false

    init(module: Module? = nil, window suppliedWindow: NSWindow? = nil) {
        let size: NSSize = module == .settings ? NSSize(width: 520, height: 430) : NSSize(width: 980, height: 680)
        let window = suppliedWindow ?? NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = module?.rawValue ?? "AI Lock"
        window.minSize = module == .settings ? NSSize(width: 500, height: 400) : NSSize(width: 760, height: 500)
        window.backgroundColor = canvas
        super.init(window: window)
        self.module = module
        if let module { buildModuleWindow(module) }
        initializeExtraServices()
        if module == .clipboard {
            clipboardHistory.onChange = { [weak self] in self?.refreshClipboardTable() }
            clipboardHistory.start()
        }
    }

    private var module: Module?

    private func buildModuleWindow(_ module: Module) {
        guard let window else { return }
        let root = NSView(frame: NSRect(origin: .zero, size: window.contentView?.bounds.size ?? window.frame.size))
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root
        if let content = window.contentView {
            NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor), root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)])
        }
        moduleRoot = root
        switch module {
        case .dockLock, .dockLockSettings: showDockLockSettings()
        case .cacheCleaner: showCacheCleaner()
        case .uninstaller: showUninstaller()
        case .launchItems: showLaunchItems()
        case .files: showFileAudit()
        case .processes: showProcesses()
        case .network: showNetwork()
        case .logs: showLogs()
        case .clipboard: showClipboard()
        case .settings: showSettings()
        case .preferences: Self.openPreferences()
        case .search: showQuickSearch()
        case .launcher: showQuickSearch()
        }
        activeModuleWindow = window
        window.center()
    }

    static func open(_ module: Module) -> DashboardWindow {
        let controller: DashboardWindow
        if let existing = moduleWindows[module] {
            controller = existing
        } else {
            controller = DashboardWindow(module: module)
            moduleWindows[module] = controller
        }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    static func openPreferences() {
        let controller = preferencesWindow ?? PreferencesWindowController()
        preferencesWindow = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func openCommandPalette() {
        _ = open(.files)
        DispatchQueue.main.async {
            guard let controller = moduleWindows[.files] else { return }
            controller.paletteSearchField?.stringValue = ""
            controller.refreshPalette()
            controller.paletteSearchField?.becomeFirstResponder()
        }
    }

    static func setDockLockController(_ controller: DockLock) { lockController = controller }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func addModule(_ page: NSView) {
        guard let moduleRoot else { return }
        page.translatesAutoresizingMaskIntoConstraints = false
        moduleRoot.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: moduleRoot.leadingAnchor, constant: 24),
            page.trailingAnchor.constraint(equalTo: moduleRoot.trailingAnchor, constant: -24),
            page.topAnchor.constraint(equalTo: moduleRoot.topAnchor, constant: 20),
            page.bottomAnchor.constraint(equalTo: moduleRoot.bottomAnchor, constant: -20)
        ])
    }

    private func card() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink, mono: Bool = false) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        let compactSize = min(size, 12)
        result.font = mono ? .monospacedSystemFont(ofSize: compactSize, weight: weight) : .systemFont(ofSize: compactSize, weight: weight)
        result.textColor = color
        result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }

    private func showLogs() {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let status = label("正在查询 macOS 统一日志…", size: 11, color: muted)
        let search = NSSearchField()
        search.placeholderString = "搜索消息、子系统、类别或进程"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.focusRingType = .none
        search.target = self
        search.action = #selector(logFilterChanged(_:))
        let level = NSPopUpButton()
        level.translatesAutoresizingMaskIntoConstraints = false
        SystemLogLevel.allCases.forEach { level.addItem(withTitle: $0.rawValue) }
        level.target = self
        level.action = #selector(logFilterChanged(_:))

        let table = NSTableView()
        table.rowHeight = 34
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = cardColor
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.target = self
        table.doubleAction = #selector(showFullLogMessage(_:))
        let columns: [(String, String, CGFloat)] = [("time", "时间", 172), ("level", "级别", 76), ("process", "进程", 130), ("message", "消息", 560)]
        columns.forEach { id, title, width in
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let data = LogTableDataSource(entries: filteredLogEntries())
        table.dataSource = data
        table.delegate = data
        logTableDataSource = data
        logTable = table
        logStatusLabel = status
        logSearchField = search
        logLevelPopup = level

        [search, level, status, scroll].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 360),
            search.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), search.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: level.leadingAnchor, constant: -8),
            level.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), level.centerYAnchor.constraint(equalTo: search.centerYAnchor), level.widthAnchor.constraint(equalToConstant: 150),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -32)
        ])
        addModule(page)
        loadLogs()
    }

    private var logTableDataSource: LogTableDataSource?
    private weak var logTable: NSTableView?
    private weak var logStatusLabel: NSTextField?
    private weak var logSearchField: NSSearchField?
    private weak var logLevelPopup: NSPopUpButton?
    private let processMonitor = ProcessMonitor()
    private let processNetworkMonitor = ProcessNetworkMonitor()
    private var processTimer: Timer?
    private var processEntries: [MonitoredProcess] = []
    private weak var processTable: NSTableView?
    private weak var processSearchField: NSSearchField?
    private weak var processStatusLabel: NSTextField?
    private var processTableDataSource: ProcessTableDataSource?
    private lazy var processContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        let terminate = NSMenuItem(title: "正常退出", action: #selector(requestTerminateProcess(_:)), keyEquivalent: "")
        terminate.target = self
        let force = NSMenuItem(title: "强制结束…", action: #selector(requestForceTerminateProcess(_:)), keyEquivalent: "")
        force.target = self
        menu.addItem(terminate)
        menu.addItem(force)
        return menu
    }()
    private let resourceAlerts = ResourceAlerts()
    private let clipboardHistory = ClipboardHistory()
    private weak var searchField: NSSearchField?
    private weak var searchResultsTable: NSTableView?
    private var searchDataSource: SearchTableDataSource?
    private weak var clipboardTags: ClipboardTagView?
    private weak var clipboardSearchField: NSSearchField?
    private weak var clipboardStatus: NSTextField?
    private var clipboardTimer: Timer?
    private weak var activeModuleWindow: NSWindow?
    private weak var alertCpuField: NSTextField?
    private weak var alertDiskField: NSTextField?
    private weak var alertNetworkField: NSTextField?
    private var hotKeyRef: EventHotKeyRef?
    private static var globalHotKeyRefs: [EventHotKeyRef] = []
    private static var lastCommandPress: TimeInterval = 0
    private static var commandDoubleTapMonitor: Any?
    private static let globalHotkeyModules: [(UInt32, Module)] = [(1, .dockLockSettings), (2, .files), (3, .processes), (4, .network), (5, .logs), (6, .clipboard), (7, .settings), (8, .cacheCleaner), (9, .preferences), (10, .launcher)]
    static var hotkeyAssignments: [String: Int] {
        get {
            (UserDefaults.standard.dictionary(forKey: "overview.hotkeys") as? [String: Int]) ?? Dictionary(uniqueKeysWithValues: globalHotkeyModules.map { ($0.1.rawValue, Int($0.0)) })
        }
        set { UserDefaults.standard.set(newValue, forKey: "overview.hotkeys") }
    }
    static func refreshGlobalHotkeys() { registerGlobalHotkeys() }

    private func initializeExtraServices() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        Self.registerGlobalHotkeys()
    }

    private static func registerGlobalHotkeys() {
        globalHotKeyRefs.forEach { UnregisterEventHotKey($0) }
        globalHotKeyRefs.removeAll()
        if UserDefaults.standard.object(forKey: "hotkey.quickAction") == nil {
            UserDefaults.standard.set(0, forKey: "hotkey.quickAction")
        }
        let signature = OSType(0x41494C4B)
        let assignments = hotkeyAssignments
        for (hotkeyID, module) in globalHotkeyModules {
            let isQuickAction = hotkeyID == 10
            let configured = isQuickAction ? (UserDefaults.standard.integer(forKey: "hotkey.quickAction") == 1 ? 0 : nil) : assignments[module.rawValue]
            guard let configured, (isQuickAction ? configured == 0 : (1...9).contains(configured)),
                  isQuickAction || !assignments.filter({ $0.key != module.rawValue }).values.contains(configured) else { continue }
            let number = UInt32(configured)
            var reference: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: signature, id: hotkeyID)
            let keyCode = isQuickAction ? UInt32(kVK_Space) : UInt32(kVK_ANSI_1 + Int(number - 1))
            let modifiers = UInt32(cmdKey | controlKey | (isQuickAction ? optionKey : 0))
            guard RegisterEventHotKey(keyCode, modifiers, identifier, GetApplicationEventTarget(), 0, &reference) == noErr,
                  let reference else { continue }
            globalHotKeyRefs.append(reference)
        }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return noErr }
            var identifier = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier) == noErr,
                  let module = DashboardWindow.globalHotkeyModules.first(where: { $0.0 == identifier.id })?.1 else { return noErr }
            DispatchQueue.main.async {
                if identifier.id == 10 { DashboardWindow.openCommandPalette() }
            else if module == .preferences { DashboardWindow.openPreferences() }
            else { _ = DashboardWindow.open(module) }
            }
            return noErr
        }, 1, &eventType, nil, nil)
        if commandDoubleTapMonitor == nil {
            commandDoubleTapMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
                guard UserDefaults.standard.integer(forKey: "hotkey.quickAction") == 0,
                      (event.keyCode == UInt16(kVK_Command) || event.keyCode == UInt16(kVK_RightCommand)),
                      event.modifierFlags.contains(.command) else { return }
                let now = Date.timeIntervalSinceReferenceDate
                if now - lastCommandPress <= 0.45 {
                    lastCommandPress = 0
                    DispatchQueue.main.async { DashboardWindow.openCommandPalette() }
                } else { lastCommandPress = now }
            }
        }
    }

    private func toolbarButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        return button
    }

    private func loadLogs() {
        guard !logPaused else { return }
        logLoadGeneration += 1
        let generation = logLoadGeneration
        logEntries = []
        updateLogTable()
        logStatusLabel?.stringValue = "正在加载最近 10 分钟的系统日志…"
        logStore.fetch(onBatch: { [weak self] batch, count, finished in
            DispatchQueue.main.async {
                guard let self, generation == self.logLoadGeneration else { return }
                if !batch.isEmpty {
                    self.logEntries.insert(contentsOf: batch, at: 0)
                    if self.logEntries.count > 2_000 { self.logEntries.removeLast(self.logEntries.count - 2_000) }
                    self.updateLogTable()
                }
                self.logStatusLabel?.stringValue = finished ? "\(self.logEntries.count) 条日志" : "已加载 \(count) 条日志…"
            }
        }) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, generation == self.logLoadGeneration else { return }
                if let error {
                    self.logEntries = []
                    self.logStatusLabel?.stringValue = "读取失败：\(error.localizedDescription)"
                    self.updateLogTable()
                } else {
                    self.logStatusLabel?.stringValue = "\(self.logEntries.count) 条日志"
                }
            }
        }
    }

    private func filteredLogEntries() -> [SystemLogEntry] {
        let query = logSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = SystemLogLevel.allCases.first { $0.rawValue == logLevelPopup?.titleOfSelectedItem } ?? .all
        return logEntries.filter { entry in
            (selected == .all || entry.level == selected) &&
            (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query) ||
             entry.subsystem.localizedCaseInsensitiveContains(query) || entry.category.localizedCaseInsensitiveContains(query) ||
             entry.process.localizedCaseInsensitiveContains(query))
        }
    }

    private func updateLogTable() {
        let entries = filteredLogEntries()
        logTableDataSource?.entries = entries
        logTable?.reloadData()
        if !entries.isEmpty { logTable?.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<entries.count)) }
        logStatusLabel?.stringValue = "\(entries.count) 条日志"
    }

    @objc private func logFilterChanged(_ sender: Any?) { updateLogTable() }

    @objc private func showFullLogMessage(_ sender: Any?) {
        guard let table = logTable, table.clickedRow >= 0,
              let entry = logTableDataSource?.entries[table.clickedRow] else { return }
        let alert = NSAlert()
        alert.messageText = "系统日志消息"
        alert.informativeText = "\(entry.formattedTime)  [\(entry.level.rawValue)]  \(entry.process)\n\n\(entry.message)"
        alert.addButton(withTitle: "复制消息")
        alert.addButton(withTitle: "关闭")
        guard let targetWindow = activeModuleWindow ?? window else { return }
        alert.beginSheetModal(for: targetWindow) { response in
            guard response == .alertFirstButtonReturn else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.message, forType: .string)
        }
    }

    private func showQuickSearch() {
        if moduleRoot == nil { return }
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("QUICK FIND   /   06", size: 10, color: lime, mono: true)
        let heading = label("快速搜索", size: 15, weight: .bold)
        let subtitle = label("搜索已安装应用与 Spotlight 已索引文件 · 结果遵守系统隐私权限", size: 12, color: muted)
        let search = NSSearchField(); search.placeholderString = "输入应用名或文件名…"; search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self; search.action = #selector(runQuickSearch(_:))
        let open = toolbarButton("打开", symbol: "arrow.up.right.square", action: #selector(openSearchResult(_:))); open.isEnabled = false
        let table = NSTableView(); table.rowHeight = 24; table.backgroundColor = cardColor; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width): (String, String, CGFloat) in [("kind", "类型", 90), ("title", "名称", 240), ("path", "位置", 600)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let data = SearchTableDataSource(results: []); table.dataSource = data; table.delegate = data
        table.target = self; table.action = #selector(searchSelectionChanged(_:))
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let status = label("输入关键词后开始搜索。文件结果由 Spotlight 索引提供。", size: 11, color: muted)
        [eyebrow, heading, subtitle, search, open, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 2),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor), search.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 5), search.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -5),
            open.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), open.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 5), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        searchField = search; searchResultsTable = table; searchDataSource = data; quickSearchOpenButton = open; quickSearchStatus = status
        addModule(page)
    }

    private weak var quickSearchOpenButton: NSButton?
    private weak var quickSearchStatus: NSTextField?
    @objc private func runQuickSearch(_ sender: Any?) {
        guard let field = searchField else { return }
        let query = field.stringValue
        quickSearchStatus?.stringValue = query.isEmpty ? "输入关键词后开始搜索。" : "正在查询应用和 Spotlight 索引…"
        QuickSearch().search(query) { [weak self] results in
            guard let self else { return }
            self.searchDataSource?.results = results
            self.searchResultsTable?.reloadData()
            self.quickSearchStatus?.stringValue = "找到 \(results.count) 个结果 · 未索引或受隐私保护的位置不会出现"
        }
    }
    @objc private func searchSelectionChanged(_ sender: Any?) { quickSearchOpenButton?.isEnabled = (searchResultsTable?.selectedRow ?? -1) >= 0 }
    @objc private func openSearchResult(_ sender: Any?) {
        guard let row = searchResultsTable?.selectedRow, let result = searchDataSource?.results, result.indices.contains(row) else { return }
        QuickSearch().open(result[row])
    }

    private weak var paletteSearchField: NSSearchField?
    private weak var paletteTable: NSTableView?
    private var paletteDataSource: CommandPaletteDataSource?

    @objc private func filterPalette(_ sender: NSSearchField) { refreshPalette() }

    private func refreshPalette() {
        let query = paletteSearchField?.stringValue ?? ""
        let commands = CommandPaletteCommand.all.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.keywords.localizedCaseInsensitiveContains(query) }
        paletteDataSource?.commands = commands
        paletteTable?.reloadData()
        if !commands.isEmpty { paletteTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    @objc private func performPaletteSelection(_ sender: Any?) {
        guard let row = paletteTable?.selectedRow, let commands = paletteDataSource?.commands, commands.indices.contains(row) else { return }
        let command = commands[row]
        if let module = command.module { _ = Self.open(module) }
        else if case .scanLargeFiles? = command.action { _ = Self.open(.files); DispatchQueue.main.async { DashboardWindow.moduleWindows[.files]?.scanLargeFiles(nil) } }
        window?.close()
    }

    private func showClipboard() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let heading = label("剪贴板历史", size: 15, weight: .bold)
        let clear = toolbarButton("清空历史", symbol: "trash", action: #selector(clearClipboard(_:)))
        let search = NSSearchField(); search.translatesAutoresizingMaskIntoConstraints = false; search.placeholderString = "搜索剪贴板"
        search.target = self; search.action = #selector(filterClipboard(_:))
        let copySelected = toolbarButton("复制所选", symbol: "doc.on.doc", action: #selector(copySelectedClipboard(_:)))
        let tags = ClipboardTagView()
        tags.onCopy = { [weak self] record in self?.clipboardHistory.copyBack(record); self?.clipboardStatus?.stringValue = "已复制到系统剪贴板" }
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        tags.frame = NSRect(x: 0, y: 0, width: 700, height: 60)
        scroll.documentView = tags
        tags.scrollView = scroll
        scroll.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll, queue: .main) { [weak tags] _ in tags?.layoutTags() }
        let status = label("点击标签复制；选择多个后可批量复制。", size: 11, color: muted)
        [heading, clear, search, copySelected, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            heading.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), heading.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            clear.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), clear.centerYAnchor.constraint(equalTo: heading.centerYAnchor),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor), search.trailingAnchor.constraint(equalTo: copySelected.leadingAnchor, constant: -8), search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            copySelected.trailingAnchor.constraint(equalTo: clear.trailingAnchor), copySelected.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: clear.trailingAnchor), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        clipboardTags = tags; clipboardSearchField = search; clipboardStatus = status
        addModule(page)
        DispatchQueue.main.async { [weak self] in self?.refreshClipboardTable() }
        clipboardTimer?.invalidate(); clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshClipboardTable() }
    }

    private func refreshClipboardTable() {
        clipboardTags?.records = clipboardHistory.records
        clipboardTags?.filter = clipboardSearchField?.stringValue ?? ""
        clipboardTags?.reloadTags()
        clipboardStatus?.stringValue = "\(clipboardHistory.records.count) 条记录 · 点击标签复制"
    }
    @objc private func filterClipboard(_ sender: NSSearchField) { refreshClipboardTable() }
    @objc private func copySelectedClipboard(_ sender: Any?) {
        guard let records = clipboardTags?.selectedRecords, !records.isEmpty else { clipboardStatus?.stringValue = "请先选择要复制的标签"; return }
        clipboardHistory.copyBack(records)
        clipboardStatus?.stringValue = "已复制 \(records.count) 项到系统剪贴板"
    }
    @objc private func clearClipboard(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "清空剪贴板历史？"; alert.informativeText = "本机保存的所有记录将被删除，此操作不可撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空")
        guard let targetWindow = activeModuleWindow ?? window else { return }
        alert.beginSheetModal(for: targetWindow) { [weak self] response in if response == .alertSecondButtonReturn { self?.clipboardHistory.clear() } }
    }

    private func showNetwork() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let table = NSTableView(); table.rowHeight = 34; table.backgroundColor = cardColor; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.allowsMultipleSelection = false; table.allowsEmptySelection = true; table.selectionHighlightStyle = .none
        table.focusRingType = .none
        for (id, title, width): (String, String, CGFloat) in [("process", "应用", 200), ("protocol", "协议", 90), ("local", "本地地址", 260), ("remote", "远端 IP / 端口", 290), ("state", "状态", 140)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let filter = NSPopUpButton(); filter.translatesAutoresizingMaskIntoConstraints = false
        filter.addItem(withTitle: "所有应用"); filter.target = self; filter.action = #selector(networkApplicationChanged(_:))
        let filterLabel = label("应用筛选", size: 14, weight: .medium, color: muted)
        let top = NSStackView(views: [filterLabel, filter]); top.translatesAutoresizingMaskIntoConstraints = false; top.orientation = .horizontal; top.spacing = 8
        let eventsTable = NSTableView(); eventsTable.rowHeight = 28; eventsTable.backgroundColor = cardColor; eventsTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width): (String, String, CGFloat) in [("time", "时间", 145), ("event", "变化", 110), ("process", "应用", 180), ("remote", "远端", 370)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; eventsTable.addTableColumn(column)
        }
        let eventsData = ConnectionEventDataSource(events: []); eventsTable.dataSource = eventsData; eventsTable.delegate = eventsData; connectionEventDataSource = eventsData
        let eventScroll = NSScrollView(); eventScroll.translatesAutoresizingMaskIntoConstraints = false; eventScroll.documentView = eventsTable; eventScroll.hasVerticalScroller = true; eventScroll.drawsBackground = false
        let connectionsTitle = label("当前连接", size: 13, weight: .semibold)
        let eventsTitle = label("连接变化（本次运行）", size: 13, weight: .semibold)
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let status = label("正在读取连接…", size: 11, color: muted)
        [top, connectionsTitle, scroll, eventsTitle, eventScroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 460),
            top.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), top.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            filter.widthAnchor.constraint(equalToConstant: 240), filter.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            connectionsTitle.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), connectionsTitle.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: connectionsTitle.bottomAnchor, constant: 5), scroll.heightAnchor.constraint(equalTo: page.heightAnchor, multiplier: 0.42),
            eventsTitle.leadingAnchor.constraint(equalTo: connectionsTitle.leadingAnchor), eventsTitle.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 9),
            eventScroll.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), eventScroll.trailingAnchor.constraint(equalTo: scroll.trailingAnchor), eventScroll.topAnchor.constraint(equalTo: eventsTitle.bottomAnchor, constant: 5), eventScroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        networkTable = table; networkStatus = status; networkApplicationFilter = filter; connectionEventTable = eventsTable; addModule(page); refreshNetwork(nil)
        networkTimer?.invalidate()
        networkTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refreshNetwork(nil) }
    }

    private weak var networkTable: NSTableView?
    private weak var networkStatus: NSTextField?
    private weak var networkApplicationFilter: NSPopUpButton?
    private var networkDataSource: NetworkTableDataSource?
    private weak var connectionEventTable: NSTableView?
    private var connectionEventDataSource: ConnectionEventDataSource?
    private var networkTimer: Timer?
    @objc private func refreshNetwork(_ sender: Any?) {
        DispatchQueue.global(qos: .utility).async {
            let entries = NetworkInspector.connections()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let now = Set(entries.map(\.id))
                let added = now.subtracting(self.previousConnectionIDs)
                let removed = self.previousConnectionIDs.subtracting(now)
                for entry in entries where added.contains(entry.id) {
                    self.connectionEvents.insert(ConnectionEvent(timestamp: Date(), event: "新连接", process: entry.process, remote: entry.remote), at: 0)
                }
                for oldID in removed {
                    if let old = self.networkEntries.first(where: { $0.id == oldID }) {
                        self.connectionEvents.insert(ConnectionEvent(timestamp: Date(), event: "连接结束", process: old.process, remote: old.remote), at: 0)
                    }
                }
                self.connectionEvents = Array(self.connectionEvents.prefix(300))
                self.previousConnectionIDs = now
                self.networkEntries = entries
                if let filter = self.networkApplicationFilter {
                    let selection = filter.titleOfSelectedItem
                    filter.removeAllItems(); filter.addItem(withTitle: "所有应用")
                    Array(Set(entries.map(\.process))).sorted().forEach { filter.addItem(withTitle: $0) }
                    filter.selectItem(withTitle: selection ?? "所有应用")
                    if filter.selectedItem == nil { filter.selectItem(at: 0) }
                }
                self.updateNetworkTable()
                self.connectionEventDataSource?.events = self.connectionEvents
                self.connectionEventTable?.reloadData()
            }
        }
    }

    private func updateNetworkTable() {
        let selected = networkApplicationFilter?.titleOfSelectedItem
        let entries = selected == nil || selected == "所有应用" ? networkEntries : networkEntries.filter { $0.process == selected }
        let source = NetworkTableDataSource(entries: entries); networkDataSource = source
        networkTable?.dataSource = source; networkTable?.delegate = source; networkTable?.reloadData()
        networkStatus?.stringValue = "\(entries.count) 条连接"
    }

    @objc private func networkApplicationChanged(_ sender: NSPopUpButton) { updateNetworkTable() }

    private func showFileAudit() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let status = SecurityExtensionStatus.endpointSecurity
        let heading = label("文件活动", size: 15, weight: .bold)
        let audit = label(status.title + " · " + status.detail + " 全量审计仍需 Endpoint Security 扩展授权。", size: 11, color: muted)
        audit.lineBreakMode = .byWordWrapping
        let paletteHeading = label("快捷操作", size: 13, weight: .bold)
        let paletteSearch = NSSearchField(); paletteSearch.translatesAutoresizingMaskIntoConstraints = false; paletteSearch.placeholderString = "搜索应用、文件或操作…"
        let paletteTable = NSTableView(); paletteTable.rowHeight = 28; paletteTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        paletteTable.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title")))
        let paletteSource = CommandPaletteDataSource()
        paletteTable.dataSource = paletteSource; paletteTable.delegate = paletteSource; paletteTable.target = self; paletteTable.doubleAction = #selector(performPaletteSelection(_:))
        let paletteScroll = NSScrollView(); paletteScroll.translatesAutoresizingMaskIntoConstraints = false; paletteScroll.documentView = paletteTable; paletteScroll.hasVerticalScroller = true; paletteScroll.drawsBackground = false
        let paletteHint = label("⌘⌃⌥Space 聚焦搜索 · Enter 执行或打开", size: 10, color: muted)
        let analyze = toolbarButton("分析文件", symbol: "doc.text.magnifyingglass", action: #selector(scanLargeFiles(_:)))
        let table = NSTableView(); table.rowHeight = 30; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.backgroundColor = cardColor
        for (id, title, width): (String, String, CGFloat) in [("name", "文件", 320), ("size", "大小", 100), ("path", "位置", 520)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let source = FileAnalysisDataSource(entries: []); table.dataSource = source; table.delegate = source
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let result = label("只读扫描所选目录，不代表文件读写审计。", size: 11, color: muted)
        let categoryTable = NSTableView(); categoryTable.rowHeight = 27; categoryTable.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width): (String, String, CGFloat) in [("category", "文件类型", 200), ("count", "数量", 90), ("size", "占用空间", 120)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; categoryTable.addTableColumn(column)
        }
        let categorySource = StorageCategoryDataSource(categories: []); categoryTable.dataSource = categorySource; categoryTable.delegate = categorySource
        let categoryScroll = NSScrollView(); categoryScroll.translatesAutoresizingMaskIntoConstraints = false; categoryScroll.documentView = categoryTable; categoryScroll.hasVerticalScroller = true; categoryScroll.drawsBackground = false
        [heading, audit, paletteHeading, paletteSearch, paletteScroll, paletteHint, analyze, categoryScroll, scroll, result].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 650), heading.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), heading.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            audit.leadingAnchor.constraint(equalTo: heading.leadingAnchor), audit.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), audit.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            paletteHeading.leadingAnchor.constraint(equalTo: heading.leadingAnchor), paletteHeading.topAnchor.constraint(equalTo: audit.bottomAnchor, constant: 12),
            paletteSearch.leadingAnchor.constraint(equalTo: heading.leadingAnchor), paletteSearch.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), paletteSearch.topAnchor.constraint(equalTo: paletteHeading.bottomAnchor, constant: 6),
            paletteScroll.leadingAnchor.constraint(equalTo: paletteSearch.leadingAnchor), paletteScroll.trailingAnchor.constraint(equalTo: paletteSearch.trailingAnchor), paletteScroll.topAnchor.constraint(equalTo: paletteSearch.bottomAnchor, constant: 5), paletteScroll.heightAnchor.constraint(equalToConstant: 105),
            paletteHint.leadingAnchor.constraint(equalTo: paletteSearch.leadingAnchor), paletteHint.topAnchor.constraint(equalTo: paletteScroll.bottomAnchor, constant: 4),
            analyze.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), analyze.topAnchor.constraint(equalTo: paletteHint.bottomAnchor, constant: 8),
            categoryScroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), categoryScroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), categoryScroll.topAnchor.constraint(equalTo: analyze.bottomAnchor, constant: 8), categoryScroll.heightAnchor.constraint(equalToConstant: 135),
            scroll.leadingAnchor.constraint(equalTo: categoryScroll.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: categoryScroll.trailingAnchor), scroll.topAnchor.constraint(equalTo: categoryScroll.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: result.topAnchor, constant: -4),
            result.leadingAnchor.constraint(equalTo: heading.leadingAnchor), result.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        fileAnalysisTable = table; fileAnalysisDataSource = source; fileAnalysisStatus = result; storageCategoryTable = categoryTable; storageCategoryDataSource = categorySource
        paletteSearchField = paletteSearch; self.paletteTable = paletteTable; paletteDataSource = paletteSource
        paletteSearch.target = self; paletteSearch.action = #selector(filterPalette(_:)); refreshPalette()
        addModule(page)
    }

    private weak var fileAnalysisTable: NSTableView?
    private var fileAnalysisDataSource: FileAnalysisDataSource?
    private weak var fileAnalysisStatus: NSTextField?
    private weak var storageCategoryTable: NSTableView?
    private var storageCategoryDataSource: StorageCategoryDataSource?

    @objc private func scanLargeFiles(_ sender: Any?) {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.message = "选择要分析的目录；仅列出大于 100 MB 的普通文件，不会读取文件内容或修改文件。"
        guard panel.runModal() == .OK, let root = panel.url else { return }
        fileAnalysisStatus?.stringValue = "正在分析 \(root.path)…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let entries = FileAnalyzer.largeFiles(in: root)
            let categories = FileAnalyzer.categories(in: root)
            DispatchQueue.main.async {
                self?.fileAnalysisDataSource?.entries = entries
                self?.fileAnalysisTable?.reloadData()
                self?.storageCategoryDataSource?.categories = categories
                self?.storageCategoryTable?.reloadData()
                self?.fileAnalysisStatus?.stringValue = "找到 \(entries.count) 个大于 100 MB 的文件 · 仅分析所选目录可访问内容"
            }
        }
    }

    private func showSettings() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let clipboardRetention = NSPopUpButton(); clipboardRetention.translatesAutoresizingMaskIntoConstraints = false
        [1, 3, 7, 14, 30].forEach { clipboardRetention.addItem(withTitle: "保留 \($0) 天") }
        clipboardRetention.selectItem(withTitle: "保留 \(clipboardHistory.retentionDays) 天")
        clipboardRetention.target = self; clipboardRetention.action = #selector(clipboardRetentionChanged(_:))
        let retentionLabel = label("剪贴板历史保留期限", size: 13)
        retentionLabel.font = .systemFont(ofSize: 14)
        let cpu = numericSetting(title: "CPU 预警阈值 (%)", key: "alert.cpu", fallback: 90)
        let disk = numericSetting(title: "磁盘可用空间阈值 (GB)", key: "alert.diskGB", fallback: 10)
        let network = numericSetting(title: "网络速率阈值 (MB/s)", key: "alert.networkMB", fallback: 50)
        let hotkeyLabel = label("快速搜索快捷键", size: 13)
        hotkeyLabel.font = .systemFont(ofSize: 14)
        [cpu.0, disk.0, network.0].forEach { row in
            row.subviews.forEach { ($0 as? NSTextField)?.font = .systemFont(ofSize: 14) }
        }
        let hotkey = NSPopUpButton(); hotkey.translatesAutoresizingMaskIntoConstraints = false
        ["⌥ Space", "⌃ Space", "⌘⌥ Space"].forEach { hotkey.addItem(withTitle: $0) }
        hotkey.selectItem(withTitle: UserDefaults.standard.string(forKey: "search.hotkey") ?? "⌥ Space")
        hotkey.target = self; hotkey.action = #selector(searchHotkeyChanged(_:))
        alertCpuField = cpu.1; alertDiskField = disk.1; alertNetworkField = network.1
        let save = toolbarButton("保存阈值", symbol: "checkmark", action: #selector(saveAlertSettings(_:)))
        let text = label("预警冷却时间 5 分钟。内存告警使用 macOS 内存压力事件；危险文件操作告警需全量审计扩展，目前尚未启用。", size: 13, color: muted)
        text.font = .systemFont(ofSize: 13)
        let test = toolbarButton("发送测试通知", symbol: "bell", action: #selector(sendTestNotification(_:)))
        [cpu.0, disk.0, network.0, hotkeyLabel, hotkey, save, test, text, retentionLabel, clipboardRetention].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 400),
            cpu.0.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), cpu.0.topAnchor.constraint(equalTo: page.topAnchor, constant: 12),
            disk.0.leadingAnchor.constraint(equalTo: cpu.0.leadingAnchor), disk.0.topAnchor.constraint(equalTo: cpu.0.bottomAnchor, constant: 12),
            network.0.leadingAnchor.constraint(equalTo: cpu.0.leadingAnchor), network.0.topAnchor.constraint(equalTo: disk.0.bottomAnchor, constant: 12),
            hotkeyLabel.leadingAnchor.constraint(equalTo: cpu.0.leadingAnchor), hotkeyLabel.topAnchor.constraint(equalTo: network.0.bottomAnchor, constant: 14),
            hotkey.centerYAnchor.constraint(equalTo: hotkeyLabel.centerYAnchor), hotkey.leadingAnchor.constraint(equalTo: hotkeyLabel.trailingAnchor, constant: 8), hotkey.widthAnchor.constraint(equalToConstant: 95),
            save.leadingAnchor.constraint(equalTo: cpu.0.leadingAnchor), save.topAnchor.constraint(equalTo: hotkeyLabel.bottomAnchor, constant: 12),
            test.leadingAnchor.constraint(equalTo: save.trailingAnchor, constant: 12), test.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: cpu.0.leadingAnchor), text.topAnchor.constraint(equalTo: save.bottomAnchor, constant: 12), text.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10),
            retentionLabel.leadingAnchor.constraint(equalTo: cpu.0.leadingAnchor), retentionLabel.topAnchor.constraint(equalTo: text.bottomAnchor, constant: 20),
            clipboardRetention.leadingAnchor.constraint(equalTo: retentionLabel.trailingAnchor, constant: 12), clipboardRetention.centerYAnchor.constraint(equalTo: retentionLabel.centerYAnchor)
        ])
        addModule(page)
    }

    @objc private func clipboardRetentionChanged(_ sender: NSPopUpButton) {
        if let days = Int(sender.titleOfSelectedItem?.split(separator: " ").last ?? "3") { clipboardHistory.retentionDays = days }
    }

    private func showCacheCleaner() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let status = label("点击“开始检查”扫描用户缓存。扫描只读，执行清理前会再次确认。", size: 11, color: muted)
        cacheStatus = status
        let cleanAll = toolbarButton("确认清理所列缓存…", symbol: "trash", action: #selector(confirmCleanAllCaches(_:)))
        let refresh = toolbarButton("开始检查", symbol: "stethoscope", action: #selector(refreshCaches(_:)))
        let cleanSelected = toolbarButton("清理所选缓存…", symbol: "trash", action: #selector(confirmCleanSelectedCache(_:)))
        cleanSelected.isEnabled = false
        cleanSelected.target = self
        let toolbar = NSStackView(views: [cleanSelected, cleanAll, refresh])
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.orientation = .horizontal; toolbar.spacing = 8
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.hasVerticalScroller = true
        let table = NSTableView(); table.rowHeight = 34; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = cardColor; table.allowsMultipleSelection = false; table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular; table.target = self; table.action = #selector(cacheSelectionChanged(_:))
        let name = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")); name.title = "项目名称"; name.width = 560
        let size = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size")); size.title = "占用"; size.width = 120
        [name, size].forEach(table.addTableColumn)
        let source = CacheTableDataSource(entries: cacheEntries)
        cacheDataSource = source; cacheTable = table; table.dataSource = source; table.delegate = source
        scroll.documentView = table; scroll.drawsBackground = false
        [toolbar, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            toolbar.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), toolbar.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        cacheCleanSelectedButton = cleanSelected
        updateCacheStatus()
        addModule(page)
    }

    private weak var cacheCleanSelectedButton: NSButton?

    @objc private func cacheSelectionChanged(_ sender: NSTableView) {
        cacheCleanSelectedButton?.isEnabled = sender.selectedRow >= 0
    }

    @objc private func confirmCleanSelectedCache(_ sender: Any?) {
        guard let row = cacheTable?.selectedRow, cacheEntries.indices.contains(row) else { return }
        confirmCleanCache(cacheEntries[row])
    }

    private func updateCacheStatus() {
        let total = cacheEntries.reduce(Int64(0)) { $0 + $1.size }
        let summary = "缓存分类：\(cacheEntries.count) 个应用缓存目录 · 预计释放 \(CacheCleaner.formattedSize(total))"
        cacheStatus?.stringValue = cacheScanInProgress ? "正在加载… 已显示 \(summary)" : summary
        cacheDataSource?.entries = cacheEntries
        cacheTable?.reloadData()
    }

    @objc private func refreshCaches(_ sender: Any?) {
        scanCaches()
    }

    private func scanCaches() {
        cacheScanGeneration += 1
        let generation = cacheScanGeneration
        cacheScanInProgress = true
        cacheEntries = []
        cacheDataSource?.entries = []
        cacheTable?.reloadData()
        cacheStatus?.stringValue = "正在加载缓存目录…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            CacheCleaner.scanBatches { batch, isComplete in
                DispatchQueue.main.async {
                    guard let self, generation == self.cacheScanGeneration else { return }
                    self.cacheEntries.append(contentsOf: batch)
                    self.cacheEntries.sort { $0.size > $1.size }
                    if isComplete { self.cacheScanInProgress = false }
                    self.updateCacheStatus()
                }
            }
        }
    }

    private func confirmCleanCache(_ entry: CacheEntry) {
        let alert = NSAlert(); alert.messageText = "清理 \(entry.name)？"; alert.informativeText = "将删除此应用缓存目录中的内容（\(CacheCleaner.formattedSize(entry.size))），不会删除应用数据。运行中的应用可能会重新生成缓存。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清理")
        guard let window = activeModuleWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, CacheCleaner.clean(entry) else { return }
            self?.refreshCaches(nil)
        }
    }

    @objc private func confirmCleanAllCaches(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "清理全部用户应用缓存？"; alert.informativeText = "将清空列出的用户级应用缓存目录，不会清理系统缓存或应用数据。应用可能重新生成缓存。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清理全部")
        guard let window = activeModuleWindow else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            let result = CacheCleaner.cleanAll(self.cacheEntries)
            self.refreshCaches(nil)
            self.cacheStatus?.stringValue += " · 成功 \(result.cleaned)，失败 \(result.failed)"
        }
    }

    private func showUninstaller() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let status = label("正在扫描用户与系统 Applications 目录…", size: 11, color: muted)
        let remove = toolbarButton("卸载所选应用…", symbol: "trash", action: #selector(confirmUninstall(_:))); remove.isEnabled = false
        let refresh = toolbarButton("刷新", symbol: "arrow.clockwise", action: #selector(refreshApplications(_:)))
        let toolbar = NSStackView(views: [remove, refresh]); toolbar.translatesAutoresizingMaskIntoConstraints = false; toolbar.orientation = .horizontal; toolbar.spacing = 8
        let table = NSTableView(); table.rowHeight = 40; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle; table.backgroundColor = cardColor; table.allowsMultipleSelection = false
        table.target = self; table.action = #selector(applicationSelectionChanged(_:))
        for (id, title, width): (String, String, CGFloat) in [("name", "应用", 250), ("size", "应用大小", 110), ("path", "位置", 520)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let source = InstalledAppDataSource(entries: []); table.dataSource = source; table.delegate = source
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let hint = label("卸载会将应用及可识别的用户级容器/偏好设置移入废纸篓；系统目录应用只移除应用本体。不会强制结束运行中的应用。", size: 11, color: muted)
        hint.lineBreakMode = .byWordWrapping
        [toolbar, scroll, status, hint].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 360), toolbar.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), toolbar.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), status.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -4),
            hint.leadingAnchor.constraint(equalTo: status.leadingAnchor), hint.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), hint.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        uninstallerTable = table; uninstallerDataSource = source; uninstallerStatus = status; uninstallerButton = remove
        addModule(page); refreshApplications(nil)
    }

    private func showLaunchItems() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let status = label("正在只读扫描启动项和后台常驻配置…", size: 11, color: muted)
        let refresh = toolbarButton("重新扫描", symbol: "arrow.clockwise", action: #selector(refreshLaunchItems(_:)))
        let table = NSTableView(); table.rowHeight = 34; table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        for (id, title, width): (String, String, CGFloat) in [("label", "项目", 210), ("kind", "来源", 170), ("enabled", "启动状态", 100), ("program", "程序路径", 520)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let source = StartupItemDataSource(items: [], table: table); table.dataSource = source; table.delegate = source
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let note = label("只检查 plist 中声明的 LaunchAgents/LaunchDaemons；不包含所有现代登录项，也不会启用、禁用或修改任何项目。", size: 11, color: muted); note.lineBreakMode = .byWordWrapping
        [refresh, scroll, status, note].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 400), refresh.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), refresh.topAnchor.constraint(equalTo: page.topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: refresh.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), status.bottomAnchor.constraint(equalTo: note.topAnchor, constant: -4),
            note.leadingAnchor.constraint(equalTo: status.leadingAnchor), note.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), note.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -8)
        ])
        launchItemsDataSource = source; launchItemsStatus = status; addModule(page); refreshLaunchItems(nil)
    }

    private var launchItemsDataSource: StartupItemDataSource?
    private weak var launchItemsStatus: NSTextField?
    @objc private func refreshLaunchItems(_ sender: Any?) {
        launchItemsStatus?.stringValue = "正在读取 plist…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let items = StartupItemInspector.scan()
            DispatchQueue.main.async {
                self?.launchItemsDataSource?.items = items
                self?.launchItemsDataSource?.reload()
                self?.launchItemsStatus?.stringValue = "发现 \(items.count) 个可读项目"
            }
        }
    }

    private var installedApps: [InstalledApplication] = []
    private weak var uninstallerTable: NSTableView?
    private var uninstallerDataSource: InstalledAppDataSource?
    private weak var uninstallerStatus: NSTextField?
    private weak var uninstallerButton: NSButton?

    @objc private func applicationSelectionChanged(_ sender: NSTableView) { uninstallerButton?.isEnabled = sender.selectedRow >= 0 }

    @objc private func refreshApplications(_ sender: Any?) {
        uninstallerStatus?.stringValue = "正在扫描应用…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let apps = ApplicationUninstaller.scan()
            DispatchQueue.main.async {
                self?.installedApps = apps; self?.uninstallerDataSource?.entries = apps; self?.uninstallerTable?.reloadData()
                self?.uninstallerStatus?.stringValue = "找到 \(apps.count) 个应用 · 选择项目查看并确认卸载"
            }
        }
    }

    @objc private func confirmUninstall(_ sender: Any?) {
        guard let row = uninstallerTable?.selectedRow, installedApps.indices.contains(row) else { return }
        let app = installedApps[row]
        let related = ApplicationUninstaller.relatedItems(for: app)
        let relatedSize = related.reduce(Int64(0)) { $0 + $1.size }
        let alert = NSAlert(); alert.messageText = "卸载 \(app.name)？"
        alert.informativeText = "应用：\(app.url.path)（\(CacheCleaner.formattedSize(app.size))）\n\n可识别的用户级残留：\(related.count) 项（\(CacheCleaner.formattedSize(relatedSize))）\n\n所选内容将移入废纸篓，不会立即永久删除。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移入废纸篓")
        guard let target = activeModuleWindow else { return }
        alert.beginSheetModal(for: target) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            let result = ApplicationUninstaller.uninstall(app, relatedItems: related)
            self?.uninstallerStatus?.stringValue = result ? "已移入废纸篓" : "卸载未完成：部分项目无法移入废纸篓"
            self?.refreshApplications(nil)
        }
    }

    private func showDockLockSettings() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let title = label("DockLock 设置", size: 20, weight: .bold)
        let targetLabel = label("目标显示器", size: 13)
        let target = NSPopUpButton(); target.translatesAutoresizingMaskIntoConstraints = false
        target.addItem(withTitle: "自动（主屏优先）")
        target.lastItem?.representedObject = "builtin"
        for display in Self.lockController?.screenChoices ?? [] {
            target.addItem(withTitle: "\(display.name) · \(display.size)")
            target.lastItem?.representedObject = String(display.id)
        }
        target.selectItem(at: 0)
        if let setting = Self.lockController?.targetSetting,
           let index = target.itemArray.firstIndex(where: { ($0.representedObject as? String) == setting }) {
            target.selectItem(at: index)
        }
        target.target = self; target.action = #selector(dockLockTargetChanged(_:))

        let margin = numericSetting(title: "屏幕边缘拦截厚度 (pt)", key: "edgeMargin", fallback: 6)
        let autoSnap = NSButton(checkboxWithTitle: "Dock 偏离时自动拉回", target: self, action: #selector(dockLockSnapChanged(_:)))
        autoSnap.state = UserDefaults.standard.object(forKey: "autoSnap") == nil || UserDefaults.standard.bool(forKey: "autoSnap") ? .on : .off
        let enabled = NSButton(checkboxWithTitle: "启用 DockLock", target: self, action: #selector(dockLockEnabledChanged(_:)))
        enabled.state = (Self.lockController?.enabled ?? false) ? .on : .off
        let privacyTitle = label("显示器隐私黑屏", size: 15, weight: .semibold)
        let privacyHint = label("点击显示器预览即可黑屏，再次点击恢复显示。", size: 12)
        let displays = Self.lockController?.screenChoices ?? []
        let displayCards = NSStackView()
        displayCards.translatesAutoresizingMaskIntoConstraints = false
        displayCards.orientation = .horizontal
        displayCards.alignment = .top
        displayCards.distribution = .fillEqually
        displayCards.spacing = 12
        for display in displays {
            displayCards.addArrangedSubview(DisplayPrivacyCard(display: display))
        }
        [title, targetLabel, target, margin.0, autoSnap, enabled, privacyTitle, privacyHint, displayCards].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 24), title.topAnchor.constraint(equalTo: page.topAnchor, constant: 24),
            targetLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor), targetLabel.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 24),
            target.leadingAnchor.constraint(equalTo: targetLabel.trailingAnchor, constant: 16), target.centerYAnchor.constraint(equalTo: targetLabel.centerYAnchor), target.widthAnchor.constraint(equalToConstant: 280),
            margin.0.leadingAnchor.constraint(equalTo: title.leadingAnchor), margin.0.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 20),
            autoSnap.leadingAnchor.constraint(equalTo: title.leadingAnchor), autoSnap.topAnchor.constraint(equalTo: margin.0.bottomAnchor, constant: 18),
            enabled.leadingAnchor.constraint(equalTo: title.leadingAnchor), enabled.topAnchor.constraint(equalTo: autoSnap.bottomAnchor, constant: 12),
            privacyTitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), privacyTitle.topAnchor.constraint(equalTo: enabled.bottomAnchor, constant: 26),
            privacyHint.leadingAnchor.constraint(equalTo: title.leadingAnchor), privacyHint.topAnchor.constraint(equalTo: privacyTitle.bottomAnchor, constant: 6),
            displayCards.leadingAnchor.constraint(equalTo: title.leadingAnchor), displayCards.trailingAnchor.constraint(lessThanOrEqualTo: page.trailingAnchor, constant: -24),
            displayCards.topAnchor.constraint(equalTo: privacyHint.bottomAnchor, constant: 12), displayCards.heightAnchor.constraint(equalToConstant: 154)
        ])
        addModule(page)
    }

    @objc private func dockLockTargetChanged(_ sender: NSPopUpButton) {
        guard let value = sender.selectedItem?.representedObject as? String else { return }
        Self.lockController?.setTarget(value)
    }

    @objc private func dockLockSnapChanged(_ sender: NSButton) {
        UserDefaults.standard.set(sender.state == .on, forKey: "autoSnap")
    }

    @objc private func dockLockEnabledChanged(_ sender: NSButton) {
        sender.state = (Self.lockController?.toggleEnabled() ?? false) ? .on : .off
    }

    @objc fileprivate func toggleDisplayPrivacy(_ sender: NSButton) {
        DisplayPrivacyManager.shared.toggle(CGDirectDisplayID(sender.tag))
    }

    private func numericSetting(title: String, key: String, fallback: Double) -> (NSView, NSTextField) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let name = label(title, size: 13)
        let field = NSTextField(string: "\(UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key))")
        field.translatesAutoresizingMaskIntoConstraints = false; field.alignment = .right
        row.addSubview(name); row.addSubview(field)
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: 270), row.heightAnchor.constraint(equalToConstant: 22), name.leadingAnchor.constraint(equalTo: row.leadingAnchor), name.centerYAnchor.constraint(equalTo: row.centerYAnchor), field.trailingAnchor.constraint(equalTo: row.trailingAnchor), field.centerYAnchor.constraint(equalTo: row.centerYAnchor), field.widthAnchor.constraint(equalToConstant: 58)])
        return (row, field)
    }

    @objc private func saveAlertSettings(_ sender: Any?) {
        for (key, field) in [("alert.cpu", alertCpuField), ("alert.diskGB", alertDiskField), ("alert.networkMB", alertNetworkField)] {
            if let field, let value = Double(field.stringValue), value > 0 { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    @objc private func sendTestNotification(_ sender: Any?) {
        let content = UNMutableNotificationContent(); content.title = "AI Lock 测试通知"; content.body = "通知权限已配置，可收到资源预警。"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @objc private func searchHotkeyChanged(_ sender: NSPopUpButton) {
        UserDefaults.standard.set(sender.titleOfSelectedItem, forKey: "search.hotkey")
        registerSearchHotkey()
    }

    private func registerSearchHotkey() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef); self.hotKeyRef = nil }
        let choice = UserDefaults.standard.string(forKey: "search.hotkey") ?? "⌥ Space"
        let modifiers: UInt32 = choice == "⌃ Space" ? UInt32(controlKey) : (choice == "⌘⌥ Space" ? UInt32(cmdKey | optionKey) : UInt32(optionKey))
        let identifier = EventHotKeyID(signature: OSType(0x41494C4B), id: 1)
        RegisterEventHotKey(UInt32(kVK_Space), modifiers, identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            _ = Unmanaged<DashboardWindow>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { _ = DashboardWindow.open(.search) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func detailPage(title: String, number: String, status: String, detail: String) -> NSView {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("AI LOCK   /   \(number)", size: 10, color: lime, mono: true)
        let heading = label(title, size: 15, weight: .bold)
        let statusLabel = label(status, size: 10, weight: .semibold, color: NSColor.systemOrange)
        let body = NSTextField(wrappingLabelWithString: detail); body.font = .systemFont(ofSize: 9); body.textColor = muted; body.translatesAutoresizingMaskIntoConstraints = false
        [eyebrow, heading, statusLabel, body].forEach(page.addSubview)
        NSLayoutConstraint.activate([eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 8), heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 3), statusLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor), statusLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 4), body.leadingAnchor.constraint(equalTo: heading.leadingAnchor), body.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), body.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 4)])
        return page
    }

    private func showProcesses() {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let search = NSSearchField()
        search.placeholderString = "进程/路径/端口"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.focusRingType = .none
        search.target = self
        search.action = #selector(processFilterChanged(_:))

        let table = NSTableView()
        table.rowHeight = 34
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.backgroundColor = cardColor
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        table.menu = processContextMenu
        let columns: [(String, String, CGFloat)] = [("name", "进程", 180), ("pid", "PID", 72), ("cpu", "CPU", 84), ("memory", "内存", 104), ("network", "网络", 150), ("ports", "端口", 150), ("path", "可执行文件", 300), ("status", "状态", 90)]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            if ["cpu", "memory", "network"].contains(identifier) {
                column.sortDescriptorPrototype = NSSortDescriptor(key: identifier, ascending: false)
            }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "cpu", ascending: false)]
        let source = ProcessTableDataSource(entries: [])
        source.onSortChanged = { [weak self] in self?.updateProcessTable() }
        table.dataSource = source
        table.delegate = source
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let status = label("正在读取进程…", size: 11, color: muted)
        let closeUsers = toolbarButton("关闭用户进程…", symbol: "power", action: #selector(requestCloseUserProcesses(_:)))
        [search, closeUsers, scroll, status].forEach(page.addSubview)

        NSLayoutConstraint.activate([
            page.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
            search.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), search.topAnchor.constraint(equalTo: page.topAnchor, constant: 8), search.widthAnchor.constraint(equalToConstant: 200),
            closeUsers.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), closeUsers.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 10), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 18), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -4),
            status.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -10), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -32)
        ])
        processTable = table
        processSearchField = search
        processStatusLabel = status
        processTableDataSource = source
        addModule(page)
        processNetworkMonitor.start()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            self?.processNetworkMonitor.stop()
        }
        refreshProcesses(nil)
        processTimer?.invalidate()
        processTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshProcesses(nil)
        }
    }

    @objc private func refreshProcesses(_ sender: Any?) {
        processEntries = processMonitor.sample()
        let ports = ProcessPortScanner.listeningPorts()
        let rates = processNetworkMonitor.currentRates()
        for index in processEntries.indices {
            let pid = processEntries[index].pid
            processEntries[index].ports = ports[pid] ?? []
            if let rate = rates[pid] {
                processEntries[index].networkDown = rate.down
                processEntries[index].networkUp = rate.up
            }
        }
        updateProcessTable()
        processStatusLabel?.stringValue = "\(processEntries.count) 个可见进程"
    }

    private func filteredProcesses() -> [MonitoredProcess] {
        let query = processSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filtered = processEntries.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.executablePath.localizedCaseInsensitiveContains(query) || $0.ports.contains { String($0).contains(query) }
        }
        guard let descriptor = processTable?.sortDescriptors.first, let key = descriptor.key else { return filtered }
        let ascending = descriptor.ascending
        switch key {
        case "cpu": return filtered.sorted { ascending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case "memory": return filtered.sorted { ascending ? $0.memoryBytes < $1.memoryBytes : $0.memoryBytes > $1.memoryBytes }
        case "network":
            return filtered.sorted {
                let left = $0.networkDown + $0.networkUp
                let right = $1.networkDown + $1.networkUp
                return ascending ? left < right : left > right
            }
        default: return filtered
        }
    }

    private func updateProcessTable() {
        processTableDataSource?.entries = filteredProcesses()
        processTable?.reloadData()
    }

    @objc private func processFilterChanged(_ sender: Any?) { updateProcessTable() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === processContextMenu, let table = processTable else { return }
        let row = table.clickedRow
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        let process = (row >= 0 && (processTableDataSource?.entries.indices.contains(row) ?? false)) ? processTableDataSource?.entries[row] : nil
        let canAct = process.map { !$0.isProtected } ?? false
        menu.items.forEach { $0.isEnabled = canAct }
    }

    @objc private func requestTerminateProcess(_ sender: Any?) {
        guard let process = selectedProcess(), !process.isProtected else { return }
        guard let app = NSRunningApplication(processIdentifier: process.pid) else {
            showProcessResult("无法向该进程发送正常退出请求；可能是后台进程或进程已结束。")
            return
        }
        if app.terminate() {
            showProcessResult("已向 \(process.name) 发送正常退出请求。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refreshProcesses(nil) }
        } else {
            showProcessResult("正常退出请求未被接受。若确需结束，请单独确认强制结束。")
        }
    }

    @objc private func requestForceTerminateProcess(_ sender: Any?) {
        guard let process = selectedProcess(), !process.isProtected else { return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "强制结束 \(process.name)？"
        alert.informativeText = "PID \(process.pid) 将被立即终止。未保存的数据可能丢失；系统服务或其他用户进程也可能无法由当前用户结束。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "强制结束")
        guard let targetWindow = activeModuleWindow ?? window else { return }
        alert.beginSheetModal(for: targetWindow) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            guard kill(process.pid, SIGKILL) == 0 else {
                self?.showProcessResult("强制结束失败：\(String(cString: strerror(errno)))")
                return
            }
            self?.showProcessResult("已向 \(process.name)（PID \(process.pid)）发送强制终止信号。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refreshProcesses(nil) }
        }
    }

    @objc private func requestCloseUserProcesses(_ sender: Any?) {
        let myPid = getpid()
        let targets = processEntries.filter { !$0.isProtected && $0.pid > 0 && $0.pid != myPid }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "关闭所有用户进程？"
        alert.informativeText = "将结束当前账户下的 \(targets.count) 个非系统进程，未保存的数据可能丢失，效果类似重新登录。系统进程（如 Finder、Dock、WindowServer）保持不变。"
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "关闭用户进程")
        guard let targetWindow = activeModuleWindow ?? window else { return }
        alert.beginSheetModal(for: targetWindow) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            self?.closeUserProcesses()
        }
    }

    private func closeUserProcesses() {
        let myPid = getpid()
        var count = 0
        for process in processEntries where !process.isProtected && process.pid > 0 && process.pid != myPid {
            if let app = NSRunningApplication(processIdentifier: process.pid), app.terminate() {
                count += 1
            } else if kill(process.pid, SIGTERM) == 0 {
                count += 1
            }
        }
        showProcessResult("已向 \(count) 个用户进程发送关闭请求。")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self else { return }
            self.processNetworkMonitor.stop()
            self.processNetworkMonitor.start()
            self.refreshProcesses(nil)
        }
    }

    private func selectedProcess() -> MonitoredProcess? {
        guard let table = processTable, table.selectedRow >= 0,
              let entries = processTableDataSource?.entries, entries.indices.contains(table.selectedRow) else { return nil }
        return entries[table.selectedRow]
    }

    private func showProcessResult(_ message: String) {
        processStatusLabel?.stringValue = message
    }
}

struct DashboardOverviewView: View {
    @State private var snapshot = SystemSnapshot.empty
    @State private var history: [NetworkHistoryPoint] = []
    @State private var query = ""
    @State private var searchResults: [SearchResult] = []
    @State private var hoverDescription = "将鼠标移到功能图标上查看说明。"
    @State private var editingShortcuts = false
    @State private var showingPreferences = false
    @State private var showingHotkeySettings = false
    @State private var draggingModule: String?
    @State private var shortcutPressID: UUID?
    @AppStorage("overview.language") private var selectedEnglish = false
    @AppStorage("overview.followSystemLanguage") private var followSystemLanguage = true
    private var english: Bool { followSystemLanguage ? Locale.preferredLanguages.first?.hasPrefix("en") ?? false : selectedEnglish }
    private var languageSelection: Binding<String> {
        Binding(get: { followSystemLanguage ? "system" : (selectedEnglish ? "en" : "zh") }, set: { value in
            followSystemLanguage = value == "system"
            if value != "system" { selectedEnglish = value == "en" }
        })
    }
    @AppStorage("overview.fontSize") private var fontSize = 13.0
    @AppStorage("overview.statusMetrics") private var statusMetricsRaw = ""
    @AppStorage("overview.visibleModules") private var visibleModulesRaw = ""
    @AppStorage("overview.moduleOrder") private var moduleOrderRaw = ""
    @State private var showingHelp = false
    @State private var dockLockEnabled = DashboardWindow.dockLockEnabled
    @State private var dockLockTarget = DashboardWindow.dockLockTargetSetting
    @State private var edgeMargin = UserDefaults.standard.object(forKey: "edgeMargin") == nil ? 6.0 : UserDefaults.standard.double(forKey: "edgeMargin")
    @State private var autoSnap = UserDefaults.standard.object(forKey: "autoSnap") == nil || UserDefaults.standard.bool(forKey: "autoSnap")
    @State private var cpuAlertThreshold = UserDefaults.standard.object(forKey: "alert.cpu") == nil ? 90.0 : UserDefaults.standard.double(forKey: "alert.cpu")
    @State private var diskAlertThreshold = UserDefaults.standard.object(forKey: "alert.diskGB") == nil ? 10.0 : UserDefaults.standard.double(forKey: "alert.diskGB")
    @State private var networkAlertThreshold = UserDefaults.standard.object(forKey: "alert.networkMB") == nil ? 50.0 : UserDefaults.standard.double(forKey: "alert.networkMB")
    private var statusMetrics: Set<String> {
        get { Set(statusMetricsRaw.split(separator: ",").map(String.init)) }
        nonmutating set { statusMetricsRaw = newValue.sorted().joined(separator: ",") }
    }
    private let monitor = SystemMonitor()
    private let search = QuickSearch()
    private let alerts = ResourceAlerts()
    private var uiScale: CGFloat { CGFloat(fontSize > 3 ? fontSize / 13 : fontSize) }
    private var scaledFontSize: CGFloat { 13 * uiScale }

    private let modules: [(String, String, DashboardWindow.Module)] = [
        ("DockLock", "dock.rectangle", .dockLock),
        ("文件活动", "doc.text.magnifyingglass", .files),
        ("应用卸载", "app.dashed", .uninstaller),
        ("启动项检查", "rectangle.stack.badge.play", .launchItems),
        ("进程管理", "cpu", .processes),
        ("网络活动", "network", .network),
        ("系统日志", "list.bullet.rectangle", .logs),
        ("剪贴板历史", "clipboard", .clipboard),
        ("系统健康检查", "stethoscope", .cacheCleaner),
        ("设置", "gearshape", .preferences)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                TextField(english ? "Search apps or files" : "搜索应用或文件", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, value in
                        search.search(value) { results in
                            searchResults = results
                        }
                    }
                    .onSubmit(runSearch)
                Button(action: runSearch) { Image(systemName: "magnifyingglass") }
                    .buttonStyle(.bordered)
            }

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(searchResults.prefix(5)) { result in
                        Button {
                            search.open(result)
                            search.cancel()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: result.kind == .application ? "app" : "doc")
                                    .foregroundStyle(.secondary)
                                Text(result.title).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(result.kind == .application ? (english ? "App" : "应用") : (english ? "File" : "文件"))
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
                metric("内存", symbol: "memorychip", value: percent(snapshot.memoryUsed, snapshot.memoryTotal), isAlert: snapshot.memoryPressure == "偏高" || snapshot.memoryPressure == "严重")
                metric("硬盘", symbol: "internaldrive", value: percent(snapshot.diskUsed, snapshot.diskTotal), isAlert: diskIsLow)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(english ? "Network Usage" : "网络用量")
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

            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
                ForEach(orderedVisibleModules, id: \.0) { title, symbol, module in
                    Button {
                        if editingShortcuts {
                            return
                        } else if module == .dockLock {
                            dockLockEnabled = DashboardWindow.toggleDockLock()
                        } else if module == .dockLockSettings {
                            _ = DashboardWindow.open(module)
                        } else if module == .preferences {
                            DashboardWindow.openPreferences()
                        } else { _ = DashboardWindow.open(module) }
                    } label: {
                        ZStack(alignment: .topTrailing) {
                            VStack(spacing: 6) {
                                Image(systemName: symbol).font(.system(size: scaledFontSize * 1.45))
                                HStack(spacing: 3) {
                                    Text(localized(title))
                                    if module == .dockLock {
                                        Text(dockLockEnabled ? (english ? "On" : "开") : (english ? "Off" : "关"))
                                            .foregroundStyle(dockLockEnabled ? .green : .secondary)
                                    }
                                }
                                .font(.system(size: scaledFontSize - 2))
                            }
                            .frame(maxWidth: .infinity, minHeight: 58)
                            .contentShape(Rectangle())
                            if editingShortcuts {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.red)
                                    .font(.system(size: scaledFontSize))
                                    .offset(x: 5, y: -5)
                            }
                        }
                    }
                    .buttonStyle(.plain)
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
                            Button(english ? "Remove from Home" : "从首页移除", systemImage: "minus.circle") { hideModule(module) }
                            Button(english ? "Finish Editing" : "完成编辑", systemImage: "checkmark") { editingShortcuts = false }
                        }
                    }
                    .onHover { hovering in
                        if hovering { hoverDescription = description(for: module, title: title) }
                    }
                }
            }

            if editingShortcuts {
                HStack {
                    Text(english ? "Drag icons to reorder or remove them." : "拖动图标可调整顺序，右键可移除。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(english ? "Done" : "完成") { editingShortcuts = false }
                        .keyboardShortcut(.defaultAction)
                }
            }

            Spacer(minLength: 0)

            HStack {
                Text(hoverDescription)
                    .lineLimit(1)
                .foregroundStyle(.secondary)
                Spacer()
                Button {} label: {
                    Image(systemName: "questionmark.circle")
                        .imageScale(.medium)
                }
                .simultaneousGesture(TapGesture().onEnded { showingHelp = true })
                .buttonStyle(.plain)
                .help("帮助与版权")
                Button("退出") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
            }
            .font(.system(size: scaledFontSize - 1))
        }
        .padding(16)
        .frame(width: 390)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.font, .system(size: scaledFontSize))
        .sheet(isPresented: $showingPreferences) {
            VStack(alignment: .leading, spacing: 16) {
                Picker(english ? "Language" : "语言", selection: languageSelection) {
                    Text("中文").tag("zh")
                    Text("English").tag("en")
                    Text(english ? "Follow System" : "跟随系统").tag("system")
                }
                Picker(english ? "Text Size" : "文字大小", selection: $fontSize) {
                    Text(english ? "Small" : "小").tag(0.9)
                    Text(english ? "Default" : "中").tag(1.0)
                    Text(english ? "Large" : "大").tag(1.15)
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(english ? "Menu Bar Metrics" : "顶部图标后显示")
                    Toggle("CPU", isOn: metricBinding("cpu"))
                    Toggle(english ? "Memory" : "内存", isOn: metricBinding("memory"))
                    Toggle(english ? "Disk" : "硬盘", isOn: metricBinding("disk"))
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(english ? "Resource Alerts" : "监控预警")
                    thresholdRow(english ? "CPU threshold (%)" : "CPU 预警阈值 (%)", value: $cpuAlertThreshold)
                    thresholdRow(english ? "Free disk threshold (GB)" : "磁盘可用空间阈值 (GB)", value: $diskAlertThreshold)
                    thresholdRow(english ? "Network rate threshold (MB/s)" : "网络速率阈值 (MB/s)", value: $networkAlertThreshold)
                    Text(english ? "Alerts have a 5-minute cooldown. Memory alerts follow macOS memory pressure." : "预警冷却时间 5 分钟；内存告警根据 macOS 内存压力触发。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(english ? "Save Alert Thresholds" : "保存预警阈值") { saveAlertThresholds() }
                        Button(english ? "Send Test Notification" : "发送测试通知") { sendTestNotification() }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("DockLock")
                    Toggle("启用 DockLock", isOn: Binding(
                        get: { dockLockEnabled },
                        set: { enabled in
                            guard enabled != dockLockEnabled else { return }
                            dockLockEnabled = DashboardWindow.toggleDockLock()
                        }
                    ))
                    Toggle("Dock 偏离时自动拉回", isOn: $autoSnap)
                        .onChange(of: autoSnap) { _, enabled in UserDefaults.standard.set(enabled, forKey: "autoSnap") }
                    HStack {
                        Text("目标显示器")
                        Spacer()
                        Picker("目标显示器", selection: $dockLockTarget) {
                            Text("自动（主屏优先）").tag("builtin")
                            ForEach(DashboardWindow.dockLockScreens, id: \.id) { screen in
                                Text("\(screen.name) · \(screen.size)").tag(String(screen.id))
                            }
                        }
                        .labelsHidden()
                        .onChange(of: dockLockTarget) { _, value in DashboardWindow.setDockLockTarget(value) }
                    }
                    HStack {
                        Text("屏幕边缘拦截厚度 (pt)")
                        Spacer()
                        TextField("6", value: $edgeMargin, format: .number)
                            .frame(width: 60)
                            .onChange(of: edgeMargin) { _, value in UserDefaults.standard.set(value, forKey: "edgeMargin") }
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(english ? "Home Icons" : "首页功能图标")
                    ForEach(modules.filter { $0.2 != .preferences }, id: \.0) { title, _, module in
                        Toggle(localized(title), isOn: visibilityBinding(module))
                    }
                }
                Button(english ? "Feature Shortcuts…" : "功能快捷键…") {
                    showingPreferences = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showingHotkeySettings = true }
                }
                HStack {
                    Spacer()
                Button(english ? "Done" : "完成") { showingPreferences = false }
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
        .sheet(isPresented: $showingHelp) {
            VStack(alignment: .leading, spacing: 12) {
                Text(english ? "AI Lock Help" : "AI Lock 帮助说明").font(.headline)
                Text(english ? "Use feature icons to open tools. Cache cleaning only clears user app caches after confirmation." : "点击功能图标打开对应工具。缓存清理仅清理用户应用缓存，并在操作前要求确认。")
                Text("当前版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                Button(english ? "Check for Updates" : "检查新版本") { NSWorkspace.shared.open(URL(string: "https://github.com/laoguzhe/AI-Lock/releases")!) }
                Text("作者邮箱：[邮箱]")
                HStack { Spacer(); Button(english ? "Done" : "完成") { showingHelp = false }.keyboardShortcut(.defaultAction) }
            }
            .padding(20).frame(width: 340)
        }
        .sheet(isPresented: $showingHotkeySettings) {
            HotkeySettingsView(english: english, close: { showingHotkeySettings = false })
        }
        .task {
            sample()
            history = NetworkHistory.shared.snapshot()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                sample()
            }
        }
    }

    private func metric(_ title: String, symbol: String, value: String, isAlert: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: scaledFontSize, weight: .regular, design: .monospaced))
                .foregroundStyle(isAlert ? Color.red : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 38)
        .padding(.horizontal, 7)
        .help(title)
    }

    private func sample() {
        snapshot = monitor.sample()
        alerts.evaluate(snapshot)
        history = NetworkHistory.shared.snapshot(now: snapshot.timestamp)
    }

    private func runSearch() {
        if let first = searchResults.first { search.open(first) }
    }

    private func percent(_ used: UInt64, _ total: UInt64) -> String {
        guard total > 0 else { return "--" }
        return String(format: "%.0f%%", Double(used) / Double(total) * 100)
    }

    private var diskIsLow: Bool {
        guard snapshot.diskTotal > snapshot.diskUsed else { return true }
        let freeGB = Double(snapshot.diskTotal - snapshot.diskUsed) / 1_000_000_000
        return freeGB < alerts.threshold(for: .diskGB)
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

    private func thresholdRow(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(title, value: value, format: .number.precision(.fractionLength(0...1)))
                .frame(width: 72)
        }
    }

    private func saveAlertThresholds() {
        for (key, value) in [("alert.cpu", cpuAlertThreshold), ("alert.diskGB", diskAlertThreshold), ("alert.networkMB", networkAlertThreshold)] where value > 0 {
            UserDefaults.standard.set(value, forKey: key)
        }
    }

    private func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "AI Lock 测试通知"
        content.body = "通知权限已配置，可收到资源预警。"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @State private var notificationStatus = ""

    private var orderedVisibleModules: [(String, String, DashboardWindow.Module)] {
        let visible = visibleModuleIDs
        let order = orderedModuleIDs
        return modules.filter { visible.contains($0.2.rawValue) }
            .sorted { (order.firstIndex(of: $0.2.rawValue) ?? Int.max) < (order.firstIndex(of: $1.2.rawValue) ?? Int.max) }
    }

    private var visibleModuleIDs: Set<String> {
        visibleModulesRaw.isEmpty ? Set(modules.map { $0.2.rawValue }) : Set(visibleModulesRaw.split(separator: ",").map(String.init))
    }

    private var orderedModuleIDs: [String] {
        let saved = moduleOrderRaw.split(separator: ",").map(String.init)
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

    private func localized(_ title: String) -> String {
        guard english else { return title }
        return ["文件活动": "File Activity", "应用卸载": "Uninstaller", "进程管理": "Processes", "网络活动": "Network", "系统日志": "System Logs", "剪贴板历史": "Clipboard", "系统健康检查": "System Health", "设置": "Settings"][title] ?? title
    }

    private func description(for module: DashboardWindow.Module, title: String) -> String {
        let descriptions: [DashboardWindow.Module: String] = [
            .dockLock: "配置 DockLock 目标屏幕、锁定边缘和自动拉回行为。",
            .files: "查看文件审计状态和本机文件活动。",
            .processes: "查看进程资源占用并管理进程。",
            .network: "查看当前网络连接和活动流量。",
            .logs: "搜索最近的 macOS 系统日志。",
            .clipboard: "查看本机剪贴板历史记录。",
            .settings: "设置 CPU、磁盘和网络监控预警。",
            .preferences: "设置语言、字体大小和状态栏指标。",
            .search: "搜索并打开本机应用或文件。",
            .cacheCleaner: "扫描用户缓存，分类展示并在确认后清理。",
            .uninstaller: "卸载应用并预览可识别的用户级残留。"
        ]
        return descriptions[module] ?? title
    }
}

private struct NetworkSparkline: View {
    let samples: [NetworkHistoryPoint]
    @State private var pointerX: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            let now = Date.now
            let window: TimeInterval = 60 * 60
            let cutoff = now.addingTimeInterval(-window)
            let maximum = max(samples.map(\.bytesPerSecond).max() ?? 0, 1)
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
                        if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
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
                    Text("\(selected.timestamp.formatted(date: .omitted, time: .standard))  ·  \(rate(selected.bytesPerSecond))")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 5))
                        .position(x: min(max(x, 105), geometry.size.width - 105), y: 12)
                }

                Text("峰值  \(rate(maximum))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 4).padding(.bottom, 2)
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
    let english: Bool
    let close: () -> Void
    @State private var assignments = DashboardWindow.hotkeyAssignments

    private let modules: [(String, DashboardWindow.Module)] = [
        ("DockLock 设置", .dockLockSettings), ("快捷操作", .launcher), ("文件活动", .files), ("应用卸载", .uninstaller), ("启动项检查", .launchItems), ("进程管理", .processes),
        ("网络活动", .network), ("系统日志", .logs), ("剪贴板历史", .clipboard),
        ("系统健康检查", .cacheCleaner), ("设置", .preferences)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(modules, id: \.1) { title, module in
                HStack {
                    Text(english ? englishTitle(title) : title)
                    Spacer()
                    if module == .launcher {
                        Picker(title, selection: quickActionBinding) {
                            Text("⌘ 两次").tag(0)
                            Text("⌘⌃⌥Space").tag(1)
                        }.labelsHidden().frame(width: 115)
                    } else {
                    Picker(title, selection: binding(for: module)) {
                ForEach(1...9, id: \.self) { Text("⌘⌃\($0)").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 100)
                    }
                }
            }
            HStack {
                Spacer()
                Button(english ? "Done" : "完成") {
                    DashboardWindow.hotkeyAssignments = assignments
                    DashboardWindow.refreshGlobalHotkeys()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func binding(for module: DashboardWindow.Module) -> Binding<Int> {
        Binding(get: { assignments[module.rawValue] ?? defaultNumber(for: module) }, set: { assignments[module.rawValue] = $0 })
    }

    private var quickActionBinding: Binding<Int> {
        Binding(get: { UserDefaults.standard.integer(forKey: "hotkey.quickAction") }, set: {
            UserDefaults.standard.set($0, forKey: "hotkey.quickAction")
            DashboardWindow.refreshGlobalHotkeys()
        })
    }

    private func defaultNumber(for module: DashboardWindow.Module) -> Int {
        switch module {
        case .dockLockSettings: return 1
        case .files: return 2
        case .processes: return 3
        case .network: return 4
        case .logs: return 5
        case .clipboard: return 6
        case .cacheCleaner: return 7
        case .launchItems: return 8
        default: return 9
        }
    }

    private func englishTitle(_ title: String) -> String {
        ["DockLock 设置": "DockLock Settings", "快捷操作": "Quick Actions", "文件活动": "File Activity", "应用卸载": "Uninstaller", "启动项检查": "Startup Items", "进程管理": "Processes", "网络活动": "Network", "系统日志": "System Logs", "剪贴板历史": "Clipboard", "系统健康检查": "System Health", "设置": "Settings"][title] ?? title
    }
}

private final class PreferencesWindowController: NSWindowController {
    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "设置"
        window.minSize = NSSize(width: 680, height: 480)
        window.contentViewController = NSHostingController(rootView: PreferencesWindowView())
        super.init(window: window)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private struct PreferencesWindowView: View {
    private let sections = ["通用", "监控预警", "DockLock", "首页图标", "功能快捷键", "帮助/关于"]
    @State private var selection = "通用"
    @AppStorage("overview.language") private var selectedEnglish = false
    @AppStorage("overview.followSystemLanguage") private var followSystemLanguage = true
    private var english: Bool { followSystemLanguage ? Locale.preferredLanguages.first?.hasPrefix("en") ?? false : selectedEnglish }
    private var languageSelection: Binding<String> {
        Binding(get: { followSystemLanguage ? "system" : (selectedEnglish ? "en" : "zh") }, set: { value in
            followSystemLanguage = value == "system"
            if value != "system" { selectedEnglish = value == "en" }
        })
    }
    @AppStorage("overview.fontSize") private var fontSize = 1.0
    @AppStorage("overview.statusMetrics") private var statusMetricsRaw = ""
    @State private var cpu = UserDefaults.standard.object(forKey: "alert.cpu") == nil ? 90.0 : UserDefaults.standard.double(forKey: "alert.cpu")
    @State private var disk = UserDefaults.standard.object(forKey: "alert.diskGB") == nil ? 10.0 : UserDefaults.standard.double(forKey: "alert.diskGB")
    @State private var network = UserDefaults.standard.object(forKey: "alert.networkMB") == nil ? 50.0 : UserDefaults.standard.double(forKey: "alert.networkMB")
    @State private var enabled = DashboardWindow.dockLockEnabled
    @State private var target = DashboardWindow.dockLockTargetSetting
    @State private var autoSnap = UserDefaults.standard.object(forKey: "autoSnap") == nil || UserDefaults.standard.bool(forKey: "autoSnap")
    @State private var edgeMargin = UserDefaults.standard.object(forKey: "dockLock.edgeMargin") == nil ? 6.0 : UserDefaults.standard.double(forKey: "dockLock.edgeMargin")
    @AppStorage("overview.visibleModules") private var visibleModulesRaw = ""
    @State private var clipboardRetention = ClipboardHistory().retentionDays

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(english ? "SETTINGS" : "设置").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 20).padding(.bottom, 8)
                ForEach(sections, id: \.self) { section in
                    Button { selection = section } label: {
                        Label(english ? englishTitle(section) : section, systemImage: symbol(for: section))
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).padding(.horizontal, 10)
                            .background(selection == section ? Color.accentColor.opacity(0.14) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).padding(.horizontal, 8)
                }
                Spacer()
            }
            .frame(width: 190).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(english ? englishTitle(selection) : selection).font(.system(size: 22, weight: .semibold))
                    sectionContent
                }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
            }
        }
        .onChange(of: statusMetricsRaw) { _, _ in NotificationCenter.default.post(name: .statusMetricsChanged, object: nil) }
        .onChange(of: english) { _, _ in NotificationCenter.default.post(name: .statusMetricsChanged, object: nil) }
    }

    @ViewBuilder private var sectionContent: some View {
        switch selection {
        case "通用":
            Picker(english ? "Language" : "语言", selection: languageSelection) {
                Text("中文").tag("zh")
                Text("English").tag("en")
                Text(english ? "Follow System" : "跟随系统").tag("system")
            }
            Picker(english ? "Text Size" : "文字大小", selection: $fontSize) { Text("小").tag(0.9); Text("中").tag(1.0); Text("大").tag(1.15) }
            GroupBox(english ? "Menu Bar Metrics" : "状态栏指标") {
                HStack(spacing: 22) {
                    metricChoice("cpu", title: "CPU", symbol: "cpu")
                    metricChoice("memory", title: english ? "Memory" : "内存", symbol: "memorychip")
                    metricChoice("disk", title: english ? "Disk" : "硬盘", symbol: "internaldrive")
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Picker("剪贴板历史保留期限", selection: $clipboardRetention) { ForEach([1, 3, 7, 14, 30], id: \.self) { Text("保留 \($0) 天").tag($0) } }.onChange(of: clipboardRetention) { _, value in ClipboardHistory().retentionDays = value }
        case "监控预警":
            thresholdRow("CPU 预警阈值 (%)", value: $cpu)
            thresholdRow("磁盘可用空间阈值 (GB)", value: $disk)
            thresholdRow("网络速率阈值 (MB/s)", value: $network)
            Text("预警冷却时间 5 分钟；内存告警根据 macOS 内存压力触发。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("保存预警阈值") { [("alert.cpu", cpu), ("alert.diskGB", disk), ("alert.networkMB", network)].forEach { UserDefaults.standard.set($0.1, forKey: $0.0) } }; Button("发送测试通知") { sendTestNotification() } }
            if !notificationStatus.isEmpty { Text(notificationStatus).font(.caption).foregroundStyle(.secondary) }
        case "DockLock":
            Toggle("启用 DockLock", isOn: Binding(get: { enabled }, set: { value in if value != enabled { enabled = DashboardWindow.toggleDockLock() } }))
            Toggle("Dock 偏离时自动拉回", isOn: $autoSnap).onChange(of: autoSnap) { _, value in UserDefaults.standard.set(value, forKey: "autoSnap") }
            Picker("目标显示器", selection: $target) { Text("自动（主屏优先）").tag("builtin"); ForEach(DashboardWindow.dockLockScreens, id: \.id) { Text("\($0.name) · \($0.size)").tag(String($0.id)) } }.onChange(of: target) { _, value in DashboardWindow.setDockLockTarget(value) }
            Text("显示器排列 · 点击桌面预览关闭/恢复显示").font(.headline)
            ScreenTopologyView(screens: DashboardWindow.dockLockScreens)
            HStack { Text("屏幕边缘拦截厚度 (pt)"); Spacer(); TextField("6", value: $edgeMargin, format: .number).frame(width: 80) }.onChange(of: edgeMargin) { _, value in UserDefaults.standard.set(value, forKey: "edgeMargin") }
        case "首页图标":
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(92)), count: 4), spacing: 14) {
                ForEach(DashboardWindow.Module.allCasesForPreferences, id: \.rawValue) { module in
                    Button { visibilityBinding(module).wrappedValue.toggle() } label: {
                        Image(systemName: moduleSymbol(module))
                            .font(.system(size: 25, weight: .medium))
                            .foregroundStyle(visibilityBinding(module).wrappedValue ? Color.accentColor : Color.secondary)
                            .frame(width: 72, height: 58)
                            .background(visibilityBinding(module).wrappedValue ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(.plain).help(module.rawValue)
                }
            }
        case "功能快捷键":
            HotkeySettingsView(english: english, close: {})
        default:
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Lock · macOS 系统工具")
                Text("用于 Dock 锁定、系统状态监控与本机维护。所有数据保存在本机。").foregroundStyle(.secondary)
                Text("版本：\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                Text("作者：AI Lock 开发者")
                Link("项目主页与更新", destination: URL(string: "https://github.com/laoguzhe/AI-Lock")!)
            }
        }
    }

    private func metricBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { statusMetricsRaw.split(separator: ",").contains(Substring(key)) }, set: { enabled in
            var values = Set(statusMetricsRaw.split(separator: ",").map(String.init)); if enabled { values.insert(key) } else { values.remove(key) }; statusMetricsRaw = values.sorted().joined(separator: ",")
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
                Text(title).font(.caption).foregroundStyle(selected ? Color.primary : Color.secondary)
            }
        }.buttonStyle(.plain)
    }

    private func moduleSymbol(_ module: DashboardWindow.Module) -> String {
        ["DockLock 设置": "dock.rectangle", "快捷操作": "command", "文件活动": "doc.text.magnifyingglass", "应用卸载": "app.dashed", "启动项检查": "rectangle.stack.badge.play", "进程管理": "cpu", "网络活动": "network", "系统日志": "list.bullet.rectangle", "剪贴板历史": "clipboard", "系统健康检查": "stethoscope", "设置": "gearshape"][module.rawValue] ?? "square"
    }

    private func visibilityBinding(_ module: DashboardWindow.Module) -> Binding<Bool> {
        Binding(get: { visibleModulesRaw.isEmpty || visibleModulesRaw.split(separator: ",").contains(Substring(module.rawValue)) }, set: { visible in
            var values = Set(visibleModulesRaw.isEmpty ? DashboardWindow.Module.allCasesForPreferences.map(\.rawValue) : visibleModulesRaw.split(separator: ",").map(String.init)); if visible { values.insert(module.rawValue) } else { values.remove(module.rawValue) }; visibleModulesRaw = values.joined(separator: ",")
        })
    }

    private func thresholdRow(_ title: String, value: Binding<Double>) -> some View {
        HStack { Text(title); Spacer(); TextField("", value: value, format: .number).frame(width: 90) }
    }

    @State private var notificationStatus = ""
    private func sendTestNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                guard granted, error == nil else { notificationStatus = "通知未授权：请在系统设置中允许 AI Lock 发送通知。"; return }
                let content = UNMutableNotificationContent(); content.title = "AI Lock 测试通知"; content.body = "通知权限已配置，可收到资源预警。"; content.sound = .default
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false))) { error in
                    DispatchQueue.main.async { notificationStatus = error.map { "发送失败：\($0.localizedDescription)" } ?? "测试通知已发送，请检查通知中心。" }
                }
            }
        }
    }

    private func symbol(for section: String) -> String { ["通用": "slider.horizontal.3", "监控预警": "bell.badge", "DockLock": "dock.rectangle", "首页图标": "square.grid.2x2", "功能快捷键": "keyboard", "帮助/关于": "info.circle"] [section] ?? "gearshape" }
    private func englishTitle(_ section: String) -> String { ["通用": "General", "监控预警": "Resource Alerts", "DockLock": "DockLock", "首页图标": "Home Icons", "功能快捷键": "Shortcuts", "帮助/关于": "Help / About"][section] ?? section }
}

private extension DashboardWindow.Module {
    static var allCasesForPreferences: [DashboardWindow.Module] { [.dockLockSettings, .files, .uninstaller, .launchItems, .processes, .network, .logs, .clipboard, .cacheCleaner] }
}

private struct ScreenTopologyView: View {
    let screens: [DockLock.ScreenChoice]
    @State private var covered = DashboardWindow.coveredDisplays
    var body: some View {
        GeometryReader { proxy in
            let minX = screens.map(\.bounds.minX).min() ?? 0
            let minY = screens.map(\.bounds.minY).min() ?? 0
            let maxX = screens.map(\.bounds.maxX).max() ?? 1
            let maxY = screens.map(\.bounds.maxY).max() ?? 1
            let scale = min(proxy.size.width / max(maxX - minX, 1), 190 / max(maxY - minY, 1))
            ZStack(alignment: .topLeading) {
                ForEach(screens, id: \.id) { screen in
                    Button {
                        DashboardWindow.toggleDisplayPrivacy(screen.id)
                        covered = DashboardWindow.coveredDisplays
                    } label: {
                        ZStack {
                            Image(nsImage: wallpaper(for: screen.id) ?? NSImage(systemSymbolName: "display", accessibilityDescription: nil)!)
                                .resizable().scaledToFill()
                            if covered.contains(screen.id) { Color.black.opacity(0.85) }
                        }
                        .frame(width: max(48, screen.bounds.width * scale - 12), height: max(40, screen.bounds.height * scale - 20)).clipped()
                        .padding(5)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.secondary.opacity(0.5)))
                    }.buttonStyle(.plain)
                    .position(x: ((screen.bounds.midX - minX) * scale) + max(48, screen.bounds.width * scale) / 2,
                              y: ((screen.bounds.midY - minY) * scale) + max(48, screen.bounds.height * scale) / 2)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(height: 220)
    }

    private func wallpaper(for id: CGDirectDisplayID) -> NSImage? {
        guard let screen = NSScreen.screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }),
              let url = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        return NSImage(contentsOf: url)
    }

}

private final class DisplayPrivacyCard: NSView {
    init(display: DockLock.ScreenChoice) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let preview = NSButton(title: "", target: nil, action: nil)
        preview.translatesAutoresizingMaskIntoConstraints = false
        preview.isBordered = false
        preview.imagePosition = .imageOnly
        preview.imageScaling = .scaleProportionallyUpOrDown
        preview.target = self
        preview.action = #selector(togglePrivacy(_:))
        preview.tag = Int(display.id)
        preview.toolTip = "点击切换此显示器的隐私黑屏"
        preview.image = Self.previewImage(for: display.id)

        let caption = NSTextField(labelWithString: "\(display.name) · \(display.size)")
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
    var coveredIDs: Set<CGDirectDisplayID> { Set(overlays.keys) }
    private let defaultsKey = "privacyBlackoutDisplays"

    private init() {
        let saved = Set(UserDefaults.standard.array(forKey: defaultsKey) as? [UInt32] ?? [])
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  saved.contains(number.uint32Value) else { continue }
            show(number.uint32Value, on: screen)
        }
    }

    func toggle(_ displayID: CGDirectDisplayID) {
        if let window = overlays.removeValue(forKey: displayID) {
            window.close()
        } else if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) {
            show(displayID, on: screen)
        }
        UserDefaults.standard.set(Array(overlays.keys), forKey: defaultsKey)
    }

    private func show(_ displayID: CGDirectDisplayID, on screen: NSScreen) {
        let window = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        overlays[displayID] = window
        window.orderFrontRegardless()
    }
}

private final class LogTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [SystemLogEntry]

    init(entries: [SystemLogEntry]) { self.entries = entries }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard entries.indices.contains(row), let column = tableView.tableColumns.first(where: { $0.identifier.rawValue == "message" }) else { return 34 }
        let message = entries[row].message as NSString
        let width = max(column.width - 16, 40)
        let bounds = message.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude),
                                          options: [.usesLineFragmentOrigin, .usesFontLeading],
                                          attributes: [.font: NSFont.systemFont(ofSize: 12)])
        return max(34, ceil(bounds.height) + 12)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        if identifier == "level" {
            let cell = NSTableCellView()
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            image.image = NSImage(systemSymbolName: symbol(for: entry.level), accessibilityDescription: entry.level.rawValue)
            image.contentTintColor = ink
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
        let text = NSTextField(wrappingLabelWithString: "")
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
        case "message": text.stringValue = entry.message
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

private final class ProcessTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [MonitoredProcess]
    var onSortChanged: (() -> Void)?
    private var iconCache: [String: NSImage] = [:]
    init(entries: [MonitoredProcess]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        onSortChanged?()
    }

    private func icon(for process: MonitoredProcess) -> NSImage? {
        let key = process.executablePath.isEmpty ? process.name : process.executablePath
        if let cached = iconCache[key] { return cached }
        var image = NSRunningApplication(processIdentifier: process.pid)?.icon
        if image == nil, !process.executablePath.isEmpty {
            image = NSWorkspace.shared.icon(forFile: process.executablePath)
        }
        if let image { iconCache[key] = image }
        return image
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let process = entries[row]
        if column == "name" {
            let cell = NSTableCellView()
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = icon(for: process) ?? NSImage(named: NSImage.applicationIconName)
            let text = NSTextField(labelWithString: process.name)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: 12)
            text.textColor = ink
            text.lineBreakMode = .byTruncatingTail
            text.usesSingleLineMode = true
            cell.addSubview(imageView)
            cell.addSubview(text)
            cell.imageView = imageView
            cell.textField = text
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 16),
                imageView.heightAnchor.constraint(equalToConstant: 16),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let value: String
        var color = ink
        switch column {
        case "pid": value = String(process.pid)
        case "cpu": value = String(format: "%.1f%%", process.cpuPercent)
        case "memory": value = formattedBytes(process.memoryBytes)
        case "network": value = networkDescription(process)
        case "ports": value = process.ports.isEmpty ? "—" : process.ports.map(String.init).joined(separator: ", ")
        case "path": value = process.executablePath.isEmpty ? "（路径不可见）" : process.executablePath
        case "status": value = process.isProtected ? "系统保护" : "可管理"; color = process.isProtected ? muted : ink
        default: return nil
        }
        let cell = NSTableCellView()
        let text = NSTextField(labelWithString: value)
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 12)
        text.textColor = color
        text.lineBreakMode = column == "path" ? .byTruncatingMiddle : .byTruncatingTail
        text.usesSingleLineMode = true
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        cell.addSubview(text)
        cell.textField = text
        if column == "path" {
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                text.centerXAnchor.constraint(equalTo: cell.centerXAnchor),
                text.leadingAnchor.constraint(greaterThanOrEqualTo: cell.leadingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
        }
        return cell
    }

    private func networkDescription(_ process: MonitoredProcess) -> String {
        let down = process.networkDown / 1024
        let up = process.networkUp / 1024
        if down < 0.05 && up < 0.05 { return "—" }
        return String(format: "↓%.1f ↑%.1f KB/s", down, up)
    }
}

private final class SearchTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var results: [SearchResult]
    init(results: [SearchResult]) { self.results = results }
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard results.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let result = results[row]
        let cell = NSTextField(wrappingLabelWithString: "")
        cell.font = .systemFont(ofSize: 12); cell.textColor = ink
        cell.lineBreakMode = column == "path" ? .byTruncatingMiddle : .byTruncatingTail
        switch column {
        case "kind": cell.stringValue = result.kind == .application ? "应用" : "文件"
        case "title": cell.stringValue = result.title
        case "path": cell.stringValue = result.path
        default: return nil
        }
        return cell
    }
}

private final class ClipboardTagView: NSView {
    var records: [ClipboardRecord]
    var filter = ""
    var onCopy: ((ClipboardRecord) -> Void)?
    private(set) var selectedRecords: [ClipboardRecord] = []
    private var buttons: [(NSButton, ClipboardRecord)] = []
    weak var scrollView: NSScrollView?
    private var previousWidth: CGFloat = 0
    private var tagsNeedLayout = true
    private var drawingTags = false

    override var isFlipped: Bool { true }

    init(records: [ClipboardRecord] = []) {
        self.records = records
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reloadTags() {
        tagsNeedLayout = true
        layoutTags()
    }

    func layoutTags() {
        guard !drawingTags else { return }
        let width = (scrollView?.contentView.bounds.width ?? bounds.width)
        guard width > 0 else { return }
        guard tagsNeedLayout || abs(width - previousWidth) > 1 else { return }
        drawingTags = true
        defer { drawingTags = false }
        tagsNeedLayout = false
        previousWidth = width
        subviews.forEach { $0.removeFromSuperview() }
        buttons.removeAll()
        imageViews.removeAll()
        let matching = records.filter { filter.isEmpty || $0.preview.localizedCaseInsensitiveContains(filter) }
        var x: CGFloat = 8, y: CGFloat = 8
        let maxWidth = max(200, width - 24)
        for record in matching {
            let imageData = record.values[NSPasteboard.PasteboardType.tiff.rawValue] ?? record.values[NSPasteboard.PasteboardType.png.rawValue]
            if let imageData, let image = NSImage(data: imageData) {
                let imageView = NSImageView(frame: NSRect(x: 8, y: y, width: 300, height: 1))
                imageView.image = image
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.borderWidth = 1
                imageView.layer?.borderColor = NSColor.separatorColor.cgColor
                imageView.layer?.masksToBounds = true
                imageView.toolTip = "点击图片复制"
                imageView.setAccessibilityElement(true)
                imageView.setAccessibilityRole(.button)
                imageView.setAccessibilityLabel("剪贴板图片")
                imageView.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(imageClicked(_:))))
                let imageHeight = max(1, 300 * image.size.height / max(image.size.width, 1))
                imageView.frame.size.height = imageHeight
                addSubview(imageView)
                imageViews[imageView] = record
                y += imageHeight + 10
                x = 8
                continue
            }
            let title = record.preview.isEmpty ? "空白内容" : record.preview
            let button = NSButton(title: title, target: self, action: #selector(tagClicked(_:)))
            button.bezelStyle = .rounded; button.font = .systemFont(ofSize: 12); button.setButtonType(.toggle)
            button.toolTip = title; button.lineBreakMode = .byTruncatingTail
            button.sizeToFit()
            let width = min(maxWidth, max(70, button.fittingSize.width + 16))
            if x + width > maxWidth + 8 { x = 8; y += 38 }
            button.frame = NSRect(x: x, y: y, width: width, height: 30)
            addSubview(button); buttons.append((button, record))
            x += width + 8
        }
        if matching.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: filter.isEmpty ? "暂无剪贴板记录" : "没有匹配的记录")
            empty.textColor = muted; empty.font = .systemFont(ofSize: 13); empty.frame = NSRect(x: 8, y: 12, width: maxWidth - 16, height: 28)
            addSubview(empty)
        }
        let height = max(60, max(y, 8) + 34)
        let documentWidth = max(width, maxWidth)
        frame = NSRect(x: 0, y: 0, width: documentWidth, height: height)
        invalidateIntrinsicContentSize()
        updateSelection()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(60, frame.height))
    }

    override func layout() {
        super.layout()
        layoutTags()
    }

    @objc private func tagClicked(_ sender: NSButton) {
        guard let pair = buttons.first(where: { $0.0 === sender }) else { return }
        if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
            updateSelection()
        } else {
            sender.state = .off
            onCopy?(pair.1)
        }
    }

    private var imageViews: [NSImageView: ClipboardRecord] = [:]

    @objc private func imageClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let imageView = recognizer.view as? NSImageView, let record = imageViews[imageView] else { return }
        onCopy?(record)
    }

    private func updateSelection() {
        selectedRecords = buttons.compactMap { $0.0.state == .on ? $0.1 : nil }
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
        let cell = NSTextField(labelWithString: CacheCleaner.formattedSize(entry.size))
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

private final class FileAnalysisDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [AnalyzedFile]
    init(entries: [AnalyzedFile]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let file = entries[row]
        let text: String
        switch column {
        case "name": text = file.url.lastPathComponent
        case "size": text = CacheCleaner.formattedSize(file.size)
        case "path": text = file.url.path
        default: return nil
        }
        let cell = NSTextField(labelWithString: text); cell.font = .systemFont(ofSize: 12); cell.textColor = ink
        cell.lineBreakMode = column == "path" ? .byTruncatingMiddle : .byTruncatingTail
        return cell
    }
}

private final class StorageCategoryDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var categories: [StorageCategory]
    init(categories: [StorageCategory]) { self.categories = categories }
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard categories.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let item = categories[row]
        let value: String
        switch column {
        case "category": value = item.name
        case "count": value = String(item.count)
        case "size": value = CacheCleaner.formattedSize(item.size)
        default: return nil
        }
        return NSTextField(labelWithString: value)
    }
}

private final class StartupItemDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var items: [StartupItem]
    private weak var table: NSTableView?
    init(items: [StartupItem], table: NSTableView) { self.items = items; self.table = table }
    func reload() { table?.reloadData() }
    func numberOfRows(in tableView: NSTableView) -> Int { items.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let item = items[row]
        let value: String
        switch column {
        case "label": value = item.label
        case "kind": value = item.kind
        case "enabled": value = item.enabledAtLogin ? "登录时启动" : "按需/未知"
        case "program": value = item.program
        default: return nil
        }
        let cell = NSTextField(labelWithString: value); cell.font = .systemFont(ofSize: 12); cell.lineBreakMode = .byTruncatingMiddle
        return cell
    }
}

private struct ConnectionEvent: Identifiable {
    let timestamp: Date
    let event: String
    let process: String
    let remote: String
    var id: String { "\(timestamp.timeIntervalSince1970)-\(event)-\(process)-\(remote)" }
}

private final class ConnectionEventDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var events: [ConnectionEvent]
    private let formatter = DateFormatter()
    init(events: [ConnectionEvent]) { self.events = events; formatter.dateFormat = "HH:mm:ss" }
    func numberOfRows(in tableView: NSTableView) -> Int { events.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard events.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let event = events[row]
        let value: String
        switch column {
        case "time": value = formatter.string(from: event.timestamp)
        case "event": value = event.event
        case "process": value = event.process
        case "remote": value = event.remote
        default: return nil
        }
        let cell = NSTextField(labelWithString: value); cell.font = .systemFont(ofSize: 11); cell.textColor = ink; cell.lineBreakMode = .byTruncatingTail
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
        .init(title: "打开文件活动 / 分析文件", keywords: "file large storage 大文件 文件", module: .files, action: nil),
        .init(title: "打开系统健康检查", keywords: "health cache 清理 缓存", module: .cacheCleaner, action: nil),
        .init(title: "打开应用卸载", keywords: "uninstall app 卸载 应用", module: .uninstaller, action: nil),
        .init(title: "打开启动项检查", keywords: "startup login background 后台 登录项", module: .launchItems, action: nil),
        .init(title: "打开网络活动", keywords: "network connection 网络 连接", module: .network, action: nil),
        .init(title: "打开进程管理", keywords: "process cpu memory 进程", module: .processes, action: nil),
        .init(title: "打开系统日志", keywords: "log 日志", module: .logs, action: nil),
        .init(title: "打开剪贴板历史", keywords: "clipboard 剪贴板", module: .clipboard, action: nil),
        .init(title: "检查大文件", keywords: "scan large files 大文件 分析", module: nil, action: .scanLargeFiles)
    ]
}

private final class CommandPaletteDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var commands = CommandPaletteCommand.all
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard commands.indices.contains(row) else { return nil }
        return NSTextField(labelWithString: commands[row].title)
    }
}

private final class NetworkTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let entries: [NetworkConnection]
    private var iconCache: [String: NSImage] = [:]
    init(entries: [NetworkConnection]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    private func icon(for connection: NetworkConnection) -> NSImage? {
        if let cached = iconCache[connection.process] { return cached }
        let runningApp = connection.pid > 0 ? NSRunningApplication(processIdentifier: connection.pid) : nil
        let executablePath: String? = connection.pid > 0 ? {
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            let length = proc_pidpath(connection.pid, &pathBuffer, UInt32(pathBuffer.count))
            return length > 0 ? String(cString: pathBuffer) : nil
        }() : nil
        let appBundlePath = executablePath.flatMap { path -> String? in
            let components = path.components(separatedBy: "/")
            guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
            return components.prefix(through: appIndex).joined(separator: "/")
        }
        let appURL = runningApp?.bundleURL ?? appBundlePath.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        let applicationIcon = appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        let terminalURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        let resolved = applicationIcon ?? terminalURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
        if let resolved { iconCache[connection.process] = resolved }
        return resolved
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let cell = NSTableCellView()
        if column == "process" {
            let imageView = NSImageView()
            imageView.translatesAutoresizingMaskIntoConstraints = false
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = icon(for: entry)
            let text = NSTextField(labelWithString: entry.process)
            text.translatesAutoresizingMaskIntoConstraints = false
            text.font = .systemFont(ofSize: 12); text.textColor = ink
            text.usesSingleLineMode = true
            text.lineBreakMode = .byTruncatingTail
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            cell.addSubview(imageView)
            cell.addSubview(text)
            cell.imageView = imageView
            cell.textField = text
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }
        let text = NSTextField(labelWithString: "")
        text.translatesAutoresizingMaskIntoConstraints = false
        text.font = .systemFont(ofSize: 12); text.textColor = ink
        text.usesSingleLineMode = true
        text.lineBreakMode = .byTruncatingTail
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        switch column {
        case "protocol": text.stringValue = entry.protocolName
        case "local": text.stringValue = entry.local
        case "remote": text.stringValue = entry.remote
        case "state": text.stringValue = entry.state
        default: return nil
        }
        cell.addSubview(text)
        cell.textField = text
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -6)
        ])
        return cell
    }
}

extension Notification.Name {
    static let processSelectionChanged = Notification.Name("AILockProcessSelectionChanged")
    static let statusMetricsChanged = Notification.Name("AILockStatusMetricsChanged")
}
