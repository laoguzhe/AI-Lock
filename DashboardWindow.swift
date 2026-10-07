import AppKit
import UserNotifications
import Carbon.HIToolbox

private let ink = NSColor(calibratedRed: 0.91, green: 0.94, blue: 0.98, alpha: 1)
private let muted = NSColor(calibratedRed: 0.48, green: 0.55, blue: 0.64, alpha: 1)
private let canvas = NSColor(calibratedRed: 0.055, green: 0.071, blue: 0.094, alpha: 1)
private let cardColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.14, alpha: 1)
private let lime = NSColor(calibratedRed: 0.71, green: 0.96, blue: 0.35, alpha: 1)

final class DashboardWindow: NSWindowController {
    private let monitor = SystemMonitor()
    private var timer: Timer?
    private var snapshot = SystemSnapshot.empty
    private var history: [(Date, Double)] = []
    private var cpuValue: NSTextField!
    private var cpuDetail: NSTextField!
    private var memoryValue: NSTextField!
    private var memoryDetail: NSTextField!
    private var diskValue: NSTextField!
    private var diskDetail: NSTextField!
    private var networkValue: NSTextField!
    private var networkDetail: NSTextField!
    private var pressureLabel: NSTextField!
    private var chartView: CPUChartView!
    private var refreshLabel: NSTextField!
    private var navButtons: [NSButton] = []
    private var mainContainer: NSView!
    private var mainScroll: NSScrollView!
    private var overviewPage: NSView!
    private var currentSection = 0
    private let logStore = SystemLogStore()
    private var logEntries: [SystemLogEntry] = []
    private var logPaused = false
    private var logLoadGeneration = 0

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AI Lock"
        window.minSize = NSSize(width: 920, height: 640)
        window.center()
        window.backgroundColor = canvas
        super.init(window: window)
        buildInterface()
        initializeExtraServices()
        clipboardHistory.onChange = { [weak self] in self?.refreshClipboardTable() }
        clipboardHistory.start()
        window.makeKeyAndOrderFront(nil)
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func buildInterface() {
        guard let window, let content = window.contentView else { return }
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.backgroundColor = canvas.cgColor
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor), root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor), root.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        let sidebar = NSView()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.wantsLayer = true
        sidebar.layer?.backgroundColor = NSColor(calibratedRed: 0.07, green: 0.085, blue: 0.11, alpha: 1).cgColor
        root.addSubview(sidebar)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor), sidebar.topAnchor.constraint(equalTo: root.topAnchor), sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor), sidebar.widthAnchor.constraint(equalToConstant: 218)])

        let brand = NSTextField(labelWithString: "AI  /  LOCK")
        brand.font = .monospacedSystemFont(ofSize: 16, weight: .bold)
        brand.textColor = ink
        brand.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(brand)
        NSLayoutConstraint.activate([brand.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 26), brand.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 38)])
        let liveDot = NSTextField(labelWithString: "●  LOCAL SYSTEM GUARD")
        liveDot.font = .monospacedSystemFont(ofSize: 9, weight: .medium)
        liveDot.textColor = lime
        liveDot.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(liveDot)
        NSLayoutConstraint.activate([liveDot.leadingAnchor.constraint(equalTo: brand.leadingAnchor), liveDot.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 12)])

        let nav = ["总览", "文件活动", "进程", "网络", "系统日志", "快速搜索", "剪贴板", "硬件", "设置"]
        var previous: NSLayoutYAxisAnchor = liveDot.bottomAnchor
        for (index, title) in nav.enumerated() {
            let button = NSButton(title: "  \(title)", target: self, action: #selector(sectionButtonClicked(_:)))
            button.tag = index
            button.alignment = .left
            button.isBordered = false
            button.font = .systemFont(ofSize: 13, weight: index == 0 ? .semibold : .regular)
            button.contentTintColor = index == 0 ? ink : muted
            button.translatesAutoresizingMaskIntoConstraints = false
            button.wantsLayer = true
            if index == 0 { button.layer?.backgroundColor = NSColor(calibratedRed: 0.15, green: 0.19, blue: 0.22, alpha: 1).cgColor; button.layer?.cornerRadius = 8 }
            sidebar.addSubview(button)
            NSLayoutConstraint.activate([button.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 18), button.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18), button.topAnchor.constraint(equalTo: previous, constant: index == 0 ? 30 : 7), button.heightAnchor.constraint(equalToConstant: 38)])
            previous = button.bottomAnchor
            navButtons.append(button)
        }

        let footer = NSTextField(wrappingLabelWithString: "AI Lock  ·  本机优先\n监控数据不会离开这台 Mac")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = muted
        footer.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(footer)
        NSLayoutConstraint.activate([footer.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 26), footer.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -24), footer.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -18)])

        let main = NSView()
        main.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(main)
        mainContainer = main
        NSLayoutConstraint.activate([main.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor), main.trailingAnchor.constraint(equalTo: root.trailingAnchor), main.topAnchor.constraint(equalTo: root.topAnchor), main.bottomAnchor.constraint(equalTo: root.bottomAnchor)])
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        main.addSubview(scroll)
        mainScroll = scroll
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: main.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: main.trailingAnchor), scroll.topAnchor.constraint(equalTo: main.topAnchor), scroll.bottomAnchor.constraint(equalTo: main.bottomAnchor)])

        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = page
        overviewPage = page
        NSLayoutConstraint.activate([page.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor), page.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), page.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor)])

        let eyebrow = label("SYSTEM TELEMETRY   /   01", size: 10, color: lime, mono: true)
        page.addSubview(eyebrow)
        let title = label("系统总览", size: 30, weight: .bold)
        page.addSubview(title)
        let subtitle = label("本机资源状态 · 每秒更新 · 无额外权限", size: 12, color: muted)
        page.addSubview(subtitle)
        refreshLabel = label("采样中", size: 10, color: muted, mono: true)
        page.addSubview(refreshLabel)
        NSLayoutConstraint.activate([
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 36),
            title.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), title.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 10),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor), subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            refreshLabel.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), refreshLabel.centerYAnchor.constraint(equalTo: title.centerYAnchor)
        ])

        let grid = NSGridView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 14
        grid.columnSpacing = 14
        page.addSubview(grid)
        NSLayoutConstraint.activate([grid.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), grid.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), grid.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 28)])
        let cpu = makeMetric(title: "CPU LOAD", symbol: "cpu", accent: lime)
        let memory = makeMetric(title: "MEMORY", symbol: "memorychip", accent: NSColor(calibratedRed: 0.43, green: 0.78, blue: 1, alpha: 1))
        let disk = makeMetric(title: "SYSTEM DISK", symbol: "internaldrive", accent: NSColor(calibratedRed: 0.79, green: 0.58, blue: 1, alpha: 1))
        let network = makeMetric(title: "NETWORK I/O", symbol: "arrow.left.arrow.right", accent: NSColor(calibratedRed: 1, green: 0.65, blue: 0.36, alpha: 1))
        cpuValue = cpu.value; cpuDetail = cpu.detail; memoryValue = memory.value; memoryDetail = memory.detail
        diskValue = disk.value; diskDetail = disk.detail; networkValue = network.value; networkDetail = network.detail
        grid.addRow(with: [cpu.view, memory.view]); grid.addRow(with: [disk.view, network.view])
        grid.column(at: 0).width = 330; grid.column(at: 1).width = 330

        let chartCard = card()
        page.addSubview(chartCard)
        NSLayoutConstraint.activate([chartCard.leadingAnchor.constraint(equalTo: grid.leadingAnchor), chartCard.trailingAnchor.constraint(equalTo: grid.trailingAnchor), chartCard.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 16), chartCard.heightAnchor.constraint(equalToConstant: 235)])
        let chartTitle = label("CPU ACTIVITY", size: 11, color: muted, mono: true)
        chartCard.addSubview(chartTitle)
        let legend = label("●  总使用率", size: 10, color: lime)
        chartCard.addSubview(legend)
        chartView = CPUChartView()
        chartView.translatesAutoresizingMaskIntoConstraints = false
        chartCard.addSubview(chartView)
        NSLayoutConstraint.activate([chartTitle.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 20), chartTitle.topAnchor.constraint(equalTo: chartCard.topAnchor, constant: 18), legend.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -20), legend.centerYAnchor.constraint(equalTo: chartTitle.centerYAnchor), chartView.leadingAnchor.constraint(equalTo: chartCard.leadingAnchor, constant: 14), chartView.trailingAnchor.constraint(equalTo: chartCard.trailingAnchor, constant: -14), chartView.topAnchor.constraint(equalTo: chartTitle.bottomAnchor, constant: 12), chartView.bottomAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: -14)])

        let status = card()
        page.addSubview(status)
        let statusTitle = label("安全状态", size: 14, weight: .semibold)
        status.addSubview(statusTitle)
        pressureLabel = label("●  内存压力读取中", size: 12, color: lime)
        status.addSubview(pressureLabel)
        let note = label("文件审计、逐进程网络与系统事件将在后续阶段接入", size: 11, color: muted)
        status.addSubview(note)
        NSLayoutConstraint.activate([status.leadingAnchor.constraint(equalTo: grid.leadingAnchor), status.trailingAnchor.constraint(equalTo: grid.trailingAnchor), status.topAnchor.constraint(equalTo: chartCard.bottomAnchor, constant: 16), status.heightAnchor.constraint(equalToConstant: 104), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -32), statusTitle.leadingAnchor.constraint(equalTo: status.leadingAnchor, constant: 20), statusTitle.topAnchor.constraint(equalTo: status.topAnchor, constant: 16), pressureLabel.leadingAnchor.constraint(equalTo: statusTitle.leadingAnchor), pressureLabel.topAnchor.constraint(equalTo: statusTitle.bottomAnchor, constant: 12), note.trailingAnchor.constraint(equalTo: status.trailingAnchor, constant: -20), note.centerYAnchor.constraint(equalTo: pressureLabel.centerYAnchor)])
    }

    private func makeMetric(title: String, symbol: String, accent: NSColor) -> (view: NSView, value: NSTextField, detail: NSTextField) {
        let box = card()
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
        icon.contentTintColor = accent
        icon.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(icon)
        let heading = label(title, size: 10, color: muted, mono: true)
        box.addSubview(heading)
        let value = label("--", size: 28, weight: .semibold)
        box.addSubview(value)
        let detail = label("Waiting for sample", size: 11, color: muted)
        box.addSubview(detail)
        NSLayoutConstraint.activate([box.heightAnchor.constraint(equalToConstant: 142), icon.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18), icon.topAnchor.constraint(equalTo: box.topAnchor, constant: 19), icon.widthAnchor.constraint(equalToConstant: 17), icon.heightAnchor.constraint(equalToConstant: 17), heading.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9), heading.centerYAnchor.constraint(equalTo: icon.centerYAnchor), value.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18), value.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 14), detail.leadingAnchor.constraint(equalTo: value.leadingAnchor), detail.topAnchor.constraint(equalTo: value.bottomAnchor, constant: 6)])
        return (box, value, detail)
    }

    private func card() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.wantsLayer = true
        view.layer?.backgroundColor = cardColor.cgColor
        view.layer?.cornerRadius = 12
        return view
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink, mono: Bool = false) -> NSTextField {
        let result = NSTextField(labelWithString: text)
        result.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        result.textColor = color
        result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }

    private func sample() {
        snapshot = monitor.sample()
        resourceAlerts.evaluate(snapshot)
        let cpu = snapshot.cpuUsage * 100
        cpuValue.stringValue = String(format: "%.0f%%", cpu)
        cpuDetail.stringValue = String(format: "用户 %.0f%%   ·   系统 %.0f%%", snapshot.userCPU * 100, snapshot.systemCPU * 100)
        memoryValue.stringValue = snapshot.memoryTotal == 0 ? "--" : String(format: "%.1f GB", Double(snapshot.memoryUsed) / 1_000_000_000)
        memoryDetail.stringValue = "已用 / \(String(format: "%.1f", Double(snapshot.memoryTotal) / 1_000_000_000)) GB   ·   压力\(snapshot.memoryPressure) · Swap \(formattedBytes(snapshot.swapUsed))"
        diskValue.stringValue = snapshot.diskTotal == 0 ? "--" : "\(formattedBytes(snapshot.diskUsed)) / \(formattedBytes(snapshot.diskTotal))"
        diskDetail.stringValue = "系统卷已用空间   ·   可用 \(formattedBytes(snapshot.diskTotal - min(snapshot.diskUsed, snapshot.diskTotal)))"
        networkValue.stringValue = "↓ \(formattedRate(snapshot.networkDownload))"
        networkDetail.stringValue = "↑ \(formattedRate(snapshot.networkUpload))   ·   接口累计 ↓\(formattedBytes(snapshot.totalReceived)) ↑\(formattedBytes(snapshot.totalSent))"
        pressureLabel.stringValue = "●  内存压力：\(snapshot.memoryPressure)"
        pressureLabel.textColor = snapshot.memoryPressure == "正常" ? lime : NSColor.systemOrange
        refreshLabel.stringValue = "LIVE  /  \(DateFormatter.localizedString(from: snapshot.timestamp, dateStyle: .none, timeStyle: .medium))"
        history.append((snapshot.timestamp, cpu))
        if history.count > 90 { history.removeFirst(history.count - 90) }
        chartView.samples = history
    }

    @objc private func sectionButtonClicked(_ sender: NSButton) {
        selectSection(sender.tag)
    }

    private func selectSection(_ index: Int) {
        currentSection = index
        let names = ["总览", "文件活动", "进程", "网络", "系统日志", "快速搜索", "剪贴板", "硬件", "设置"]
        for button in navButtons {
            button.font = .systemFont(ofSize: 13, weight: button.tag == index ? .semibold : .regular)
            button.contentTintColor = button.tag == index ? ink : muted
            button.layer?.backgroundColor = button.tag == index
                ? NSColor(calibratedRed: 0.15, green: 0.19, blue: 0.22, alpha: 1).cgColor : NSColor.clear.cgColor
        }
        guard index != 0 else {
            mainScroll.documentView = overviewPage
            return
        }
        if index == 4 {
            showLogs()
            return
        }
        if index == 2 {
            showProcesses()
            return
        }
        switch index {
        case 1: showFileAudit(); return
        case 3: showNetwork(); return
        case 5: showQuickSearch(); return
        case 6: showClipboard(); return
        case 7: showHardware(); return
        case 8: showSettings(); return
        default: break
        }
        mainScroll.documentView = placeholderPage(title: names[index], number: String(format: "%02d", index),
                                                  detail: "此功能已纳入 AI Lock 开发计划，将在后续阶段接入。")
    }

    private func placeholderPage(title: String, number: String, detail: String) -> NSView {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("AI LOCK   /   \(number)", size: 10, color: lime, mono: true)
        let heading = label(title, size: 30, weight: .bold)
        let description = label(detail, size: 12, color: muted)
        [eyebrow, heading, description].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor),
            page.topAnchor.constraint(equalTo: mainScroll.contentView.topAnchor),
            page.bottomAnchor.constraint(greaterThanOrEqualTo: description.bottomAnchor, constant: 40),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 36),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 10),
            description.leadingAnchor.constraint(equalTo: heading.leadingAnchor), description.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10)
        ])
        return page
    }

    private func showLogs() {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("UNIFIED LOGGING   /   05", size: 10, color: lime, mono: true)
        let heading = label("系统日志", size: 30, weight: .bold)
        let subtitle = label("最近 30 分钟 · 最多 2,000 条 · 本机查询", size: 12, color: muted)
        let status = label("正在查询 macOS 统一日志…", size: 11, color: muted)
        let queryNote = NSTextField(wrappingLabelWithString: "日志字段可能由 macOS 脱敏；可见范围受系统权限与日志保留策略限制。查询只读取系统已有日志，不清空或修改系统日志。")
        queryNote.font = .systemFont(ofSize: 11)
        queryNote.textColor = muted
        queryNote.translatesAutoresizingMaskIntoConstraints = false

        let search = NSSearchField()
        search.placeholderString = "搜索消息或子系统"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self
        search.action = #selector(logFilterChanged(_:))
        search.tag = 1
        let process = NSSearchField()
        process.placeholderString = "进程"
        process.translatesAutoresizingMaskIntoConstraints = false
        process.target = self
        process.action = #selector(logFilterChanged(_:))
        process.tag = 2
        let level = NSPopUpButton()
        level.translatesAutoresizingMaskIntoConstraints = false
        SystemLogLevel.allCases.forEach { level.addItem(withTitle: $0.rawValue) }
        level.target = self
        level.action = #selector(logFilterChanged(_:))

        let toolbar = NSStackView(views: [search, process, level])
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.orientation = .horizontal
        toolbar.spacing = 10
        toolbar.distribution = .fill

        let refresh = toolbarButton("刷新", symbol: "arrow.clockwise", action: #selector(refreshLogs(_:)))
        let pause = toolbarButton(logPaused ? "继续" : "暂停", symbol: logPaused ? "play.fill" : "pause.fill", action: #selector(toggleLogPause(_:)))
        let copy = toolbarButton("复制", symbol: "doc.on.doc", action: #selector(copyLogs(_:)))
        let actions = NSStackView(views: [refresh, pause, copy])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.spacing = 8

        let table = NSTableView()
        table.rowHeight = 40
        table.usesAlternatingRowBackgroundColors = false
        table.backgroundColor = cardColor
        table.gridStyleMask = []
        table.gridColor = NSColor(calibratedWhite: 1, alpha: 0.07)
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
        logProcessField = process
        logLevelPopup = level
        logPauseButton = pause

        [eyebrow, heading, subtitle, queryNote, toolbar, actions, status, scroll].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor),
            page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            queryNote.leadingAnchor.constraint(equalTo: subtitle.leadingAnchor), queryNote.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12), queryNote.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36),
            toolbar.leadingAnchor.constraint(equalTo: heading.leadingAnchor), toolbar.topAnchor.constraint(equalTo: queryNote.bottomAnchor, constant: 18),
            search.widthAnchor.constraint(greaterThanOrEqualToConstant: 220), process.widthAnchor.constraint(equalToConstant: 130), level.widthAnchor.constraint(equalToConstant: 120),
            actions.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), actions.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), scroll.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 10), scroll.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -28)
        ])
        mainScroll.documentView = page
        loadLogs()
    }

    private var logTableDataSource: LogTableDataSource?
    private weak var logTable: NSTableView?
    private weak var logStatusLabel: NSTextField?
    private weak var logSearchField: NSSearchField?
    private weak var logProcessField: NSSearchField?
    private weak var logLevelPopup: NSPopUpButton?
    private weak var logPauseButton: NSButton?
    private let processMonitor = ProcessMonitor()
    private var processTimer: Timer?
    private var processEntries: [MonitoredProcess] = []
    private weak var processTable: NSTableView?
    private weak var processSearchField: NSSearchField?
    private weak var processSortPopup: NSPopUpButton?
    private weak var processStatusLabel: NSTextField?
    private weak var terminateButton: NSButton?
    private weak var forceTerminateButton: NSButton?
    private var processTableDataSource: ProcessTableDataSource?
    private let resourceAlerts = ResourceAlerts()
    private let quickSearch = QuickSearch()
    private let clipboardHistory = ClipboardHistory()
    private weak var searchField: NSSearchField?
    private weak var searchResultsTable: NSTableView?
    private var searchResults: [SearchResult] = []
    private var searchDataSource: SearchTableDataSource?
    private weak var clipboardTable: NSTableView?
    private var clipboardDataSource: ClipboardTableDataSource?
    private weak var clipboardPauseButton: NSButton?
    private weak var clipboardRetentionPopup: NSPopUpButton?
    private weak var clipboardStatus: NSTextField?
    private var clipboardTimer: Timer?
    private weak var alertCpuField: NSTextField?
    private weak var alertDiskField: NSTextField?
    private weak var alertNetworkField: NSTextField?
    private var hotKeyRef: EventHotKeyRef?

    private func initializeExtraServices() {
        clipboardHistory.onChange = { [weak self] in self?.refreshClipboardTable() }
        clipboardHistory.start()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        registerSearchHotkey()
    }

    private func toolbarButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        return button
    }

    private func loadLogs() {
        guard !logPaused else { return }
        logLoadGeneration += 1
        let generation = logLoadGeneration
        logStatusLabel?.stringValue = "正在查询最近 30 分钟的系统日志…"
        logStore.fetch { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.logLoadGeneration else { return }
                switch result {
                case .success(let entries):
                    self.logEntries = entries
                    self.logStatusLabel?.stringValue = "\(entries.count) 条日志 · 最多 2,000 条 · 最新在前"
                    self.updateLogTable()
                case .failure(let error):
                    self.logEntries = []
                    self.logStatusLabel?.stringValue = "读取失败：\(error.localizedDescription)"
                    self.updateLogTable()
                }
            }
        }
    }

    private func filteredLogEntries() -> [SystemLogEntry] {
        let query = logSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let process = logProcessField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selected = SystemLogLevel.allCases.first { $0.rawValue == logLevelPopup?.titleOfSelectedItem } ?? .all
        return logEntries.filter { entry in
            (selected == .all || entry.level == selected) &&
            (process.isEmpty || entry.process.localizedCaseInsensitiveContains(process)) &&
            (query.isEmpty || entry.message.localizedCaseInsensitiveContains(query) ||
             entry.subsystem.localizedCaseInsensitiveContains(query) || entry.category.localizedCaseInsensitiveContains(query))
        }
    }

    private func updateLogTable() {
        logTableDataSource?.entries = filteredLogEntries()
        logTable?.reloadData()
    }

    @objc private func logFilterChanged(_ sender: Any?) { updateLogTable() }
    @objc private func refreshLogs(_ sender: Any?) { loadLogs() }

    @objc private func toggleLogPause(_ sender: Any?) {
        logPaused.toggle()
        logPauseButton?.title = logPaused ? "继续" : "暂停"
        logPauseButton?.image = NSImage(systemSymbolName: logPaused ? "play.fill" : "pause.fill", accessibilityDescription: nil)
        logStatusLabel?.stringValue = logPaused ? "已暂停自动刷新 · 点击继续或手动刷新" : "已恢复 · 正在查询…"
        if !logPaused { loadLogs() }
    }

    @objc private func copyLogs(_ sender: Any?) {
        let text = filteredLogEntries().map {
            "\($0.formattedTime) [\($0.level.rawValue)] \($0.process): \($0.message)"
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logStatusLabel?.stringValue = "已复制 \(filteredLogEntries().count) 条可见日志"
    }

    private func showQuickSearch() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("QUICK FIND   /   06", size: 10, color: lime, mono: true)
        let heading = label("快速搜索", size: 30, weight: .bold)
        let subtitle = label("搜索已安装应用与 Spotlight 已索引文件 · 结果遵守系统隐私权限", size: 12, color: muted)
        let search = NSSearchField(); search.placeholderString = "输入应用名或文件名…"; search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self; search.action = #selector(runQuickSearch(_:))
        let open = toolbarButton("打开", symbol: "arrow.up.right.square", action: #selector(openSearchResult(_:))); open.isEnabled = false
        let table = NSTableView(); table.rowHeight = 44; table.backgroundColor = cardColor
        for (id, title, width): (String, String, CGFloat) in [("kind", "类型", 90), ("title", "名称", 240), ("path", "位置", 600)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let data = SearchTableDataSource(results: []); table.dataSource = data; table.delegate = data
        table.target = self; table.action = #selector(searchSelectionChanged(_:))
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let status = label("输入关键词后开始搜索。文件结果由 Spotlight 索引提供。", size: 11, color: muted)
        [eyebrow, heading, subtitle, search, open, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor), page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor), search.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22), search.trailingAnchor.constraint(equalTo: open.leadingAnchor, constant: -10),
            open.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), open.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24)
        ])
        searchField = search; searchResultsTable = table; searchDataSource = data; quickSearchOpenButton = open; quickSearchStatus = status
        mainScroll.documentView = page
    }

    private weak var quickSearchOpenButton: NSButton?
    private weak var quickSearchStatus: NSTextField?
    @objc private func runQuickSearch(_ sender: Any?) {
        guard let field = searchField else { return }
        let query = field.stringValue
        quickSearchStatus?.stringValue = query.isEmpty ? "输入关键词后开始搜索。" : "正在查询应用和 Spotlight 索引…"
        quickSearch.search(query) { [weak self] results in
            guard let self else { return }
            self.searchResults = results; self.searchDataSource?.results = results
            self.searchResultsTable?.reloadData()
            self.quickSearchStatus?.stringValue = "找到 \(results.count) 个结果 · 未索引或受隐私保护的位置不会出现"
        }
    }
    @objc private func searchSelectionChanged(_ sender: Any?) { quickSearchOpenButton?.isEnabled = (searchResultsTable?.selectedRow ?? -1) >= 0 }
    @objc private func openSearchResult(_ sender: Any?) {
        guard let row = searchResultsTable?.selectedRow, searchResults.indices.contains(row) else { return }
        quickSearch.open(searchResults[row])
    }

    private func showClipboard() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("LOCAL CLIPBOARD   /   07", size: 10, color: lime, mono: true)
        let heading = label("剪贴板历史", size: 30, weight: .bold)
        let subtitle = label("仅本机保存 · Keychain 密钥加密 · 默认保留 3 天", size: 12, color: muted)
        let warning = NSTextField(wrappingLabelWithString: "剪贴板可能含密码、验证码和私人数据。记录在本机加密保存；按所选期限自动清理。暂停后不会收集新项目。可读取类型取决于来源应用向 macOS pasteboard 提供的内容。")
        warning.font = .systemFont(ofSize: 11); warning.textColor = muted; warning.translatesAutoresizingMaskIntoConstraints = false
        let pause = toolbarButton(clipboardHistory.isPaused ? "继续记录" : "暂停记录", symbol: clipboardHistory.isPaused ? "play.fill" : "pause.fill", action: #selector(toggleClipboardPause(_:)))
        let retention = NSPopUpButton(); retention.translatesAutoresizingMaskIntoConstraints = false
        [1, 3, 7, 14, 30].forEach { retention.addItem(withTitle: "保留 \($0) 天") }
        retention.selectItem(withTitle: "保留 \(clipboardHistory.retentionDays) 天"); retention.target = self; retention.action = #selector(clipboardRetentionChanged(_:))
        let clear = toolbarButton("清空历史", symbol: "trash", action: #selector(clearClipboard(_:)))
        let exclude = toolbarButton("排除当前应用", symbol: "eye.slash", action: #selector(excludeClipboardApp(_:)))
        let actions = NSStackView(views: [pause, retention, exclude, clear]); actions.translatesAutoresizingMaskIntoConstraints = false; actions.orientation = .horizontal; actions.spacing = 10
        let table = NSTableView(); table.rowHeight = 46; table.backgroundColor = cardColor
        for (id, title, width): (String, String, CGFloat) in [("time", "时间", 170), ("preview", "内容预览", 410), ("source", "来源应用", 180), ("types", "类型", 180)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let data = ClipboardTableDataSource(records: clipboardHistory.records); table.dataSource = data; table.delegate = data
        table.target = self; table.action = #selector(restoreClipboard(_:))
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let status = label("双击记录可恢复到系统剪贴板。", size: 11, color: muted)
        [eyebrow, heading, subtitle, warning, actions, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor), page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            warning.leadingAnchor.constraint(equalTo: heading.leadingAnchor), warning.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), warning.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            actions.leadingAnchor.constraint(equalTo: heading.leadingAnchor), actions.topAnchor.constraint(equalTo: warning.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), scroll.topAnchor.constraint(equalTo: actions.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24)
        ])
        clipboardTable = table; clipboardDataSource = data; clipboardPauseButton = pause; clipboardRetentionPopup = retention; clipboardStatus = status
        mainScroll.documentView = page
        clipboardTimer?.invalidate(); clipboardTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refreshClipboardTable() }
    }

    private func refreshClipboardTable() {
        clipboardDataSource?.records = clipboardHistory.records; clipboardTable?.reloadData()
        clipboardPauseButton?.title = clipboardHistory.isPaused ? "继续记录" : "暂停记录"
        clipboardStatus?.stringValue = "\(clipboardHistory.records.count) 条记录 · \(clipboardHistory.isPaused ? "记录已暂停" : "监测中") · 双击记录可恢复到剪贴板"
    }
    @objc private func toggleClipboardPause(_ sender: Any?) { clipboardHistory.setPaused(!clipboardHistory.isPaused) }
    @objc private func clipboardRetentionChanged(_ sender: NSPopUpButton) {
        if let days = Int(sender.titleOfSelectedItem?.split(separator: " ").last ?? "3") { clipboardHistory.retentionDays = days }
        refreshClipboardTable()
    }
    @objc private func clearClipboard(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "清空剪贴板历史？"; alert.informativeText = "本机保存的所有记录将被删除，此操作不可撤销。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "清空")
        alert.beginSheetModal(for: window!) { [weak self] response in if response == .alertSecondButtonReturn { self?.clipboardHistory.clear() } }
    }
    @objc private func excludeClipboardApp(_ sender: Any?) { clipboardHistory.excludeCurrentApplication(); clipboardStatus?.stringValue = "已将当前前台应用加入剪贴板排除列表" }
    @objc private func restoreClipboard(_ sender: Any?) {
        guard let row = clipboardTable?.clickedRow, clipboardHistory.records.indices.contains(row) else { return }
        clipboardHistory.copyBack(clipboardHistory.records[row]); clipboardStatus?.stringValue = "已恢复到系统剪贴板"
    }

    private func showNetwork() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("NETWORK OBSERVATION   /   04", size: 10, color: lime, mono: true)
        let heading = label("网络活动", size: 30, weight: .bold)
        let subtitle = label("TCP 连接元数据 · 普通 App 无法可靠读取完整 socket-PID 对照表", size: 12, color: muted)
        let note = NSTextField(wrappingLabelWithString: "此视图读取系统 TCP 连接表，进程归属显示为未归属；不会将整机流量伪装成逐进程统计。原始包捕获需 Network Extension packet tunnel，可能接管流量。域名关联会受 DNS 缓存和加密 DNS 影响。")
        note.font = .systemFont(ofSize: 11); note.textColor = muted; note.translatesAutoresizingMaskIntoConstraints = false
        let table = NSTableView(); table.rowHeight = 38; table.backgroundColor = cardColor
        for (id, title, width): (String, String, CGFloat) in [("protocol", "协议", 90), ("process", "进程", 100), ("local", "本地地址", 240), ("remote", "远端 IP / 端口", 260), ("state", "状态", 140)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id)); column.title = title; column.width = width; table.addTableColumn(column)
        }
        let refresh = toolbarButton("刷新连接", symbol: "arrow.clockwise", action: #selector(refreshNetwork(_:)))
        let captureStatus = label(SecurityExtensionStatus.packetCapture.title, size: 11, color: NSColor.systemOrange)
        let top = NSStackView(views: [refresh, captureStatus]); top.translatesAutoresizingMaskIntoConstraints = false; top.orientation = .horizontal; top.spacing = 16
        let scroll = NSScrollView(); scroll.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        let status = label("连接数据尚未读取", size: 11, color: muted)
        [eyebrow, heading, subtitle, note, top, scroll, status].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor), page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            note.leadingAnchor.constraint(equalTo: heading.leadingAnchor), note.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), note.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 14),
            top.leadingAnchor.constraint(equalTo: heading.leadingAnchor), top.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), scroll.topAnchor.constraint(equalTo: top.bottomAnchor, constant: 14), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24)
        ])
        networkTable = table; networkStatus = status; mainScroll.documentView = page; refreshNetwork(nil)
    }

    private weak var networkTable: NSTableView?
    private weak var networkStatus: NSTextField?
    private var networkDataSource: NetworkTableDataSource?
    @objc private func refreshNetwork(_ sender: Any?) {
        DispatchQueue.global(qos: .utility).async {
            let entries = NetworkInspector.connections()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let source = NetworkTableDataSource(entries: entries); self.networkDataSource = source
                self.networkTable?.dataSource = source; self.networkTable?.delegate = source; self.networkTable?.reloadData()
                self.networkStatus?.stringValue = "\(entries.count) 条 TCP 连接 · 此构建无法可靠归属进程或统计逐进程字节"
            }
        }
    }

    private func showFileAudit() {
        let status = SecurityExtensionStatus.endpointSecurity
        mainScroll.documentView = detailPage(title: "文件活动", number: "02", status: status.title,
                                             detail: status.detail + " 全量审计必须等 entitlement 获批并集成系统扩展后才能启用；当前没有启动文件读写监听。")
    }

    private func showHardware() {
        let data = HardwareSnapshot.read()
        let detail = "设备：\(data.model)\n架构：\(data.architecture)\n电源：\(data.powerSource)\n电池：\(data.batteryPercent.map { "\($0)%" } ?? "未检测到电池")\n温度：\(data.temperature)\n风扇：\(data.fanSpeed)\n\n当前未使用非公开温度/风扇接口；如需这些传感器，后续按机型评估第三方适配。"
        mainScroll.documentView = detailPage(title: "硬件状态", number: "08", status: "系统设备与电源信息", detail: detail)
    }

    private func showSettings() {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("PREFERENCES   /   09", size: 10, color: lime, mono: true)
        let heading = label("监控设置", size: 30, weight: .bold)
        let cpu = numericSetting(title: "CPU 预警阈值 (%)", key: "alert.cpu", fallback: 90)
        let disk = numericSetting(title: "磁盘可用空间阈值 (GB)", key: "alert.diskGB", fallback: 10)
        let network = numericSetting(title: "网络速率阈值 (MB/s)", key: "alert.networkMB", fallback: 50)
        let hotkeyLabel = label("快速搜索快捷键", size: 13)
        let hotkey = NSPopUpButton(); hotkey.translatesAutoresizingMaskIntoConstraints = false
        ["⌥ Space", "⌃ Space", "⌘⌥ Space"].forEach { hotkey.addItem(withTitle: $0) }
        hotkey.selectItem(withTitle: UserDefaults.standard.string(forKey: "search.hotkey") ?? "⌥ Space")
        hotkey.target = self; hotkey.action = #selector(searchHotkeyChanged(_:))
        alertCpuField = cpu.1; alertDiskField = disk.1; alertNetworkField = network.1
        let save = toolbarButton("保存阈值", symbol: "checkmark", action: #selector(saveAlertSettings(_:)))
        let text = label("预警冷却时间 5 分钟。内存告警使用 macOS 内存压力事件；危险文件操作告警需全量审计扩展，目前尚未启用。", size: 11, color: muted)
        let test = toolbarButton("发送测试通知", symbol: "bell", action: #selector(sendTestNotification(_:)))
        [eyebrow, heading, cpu.0, disk.0, network.0, hotkeyLabel, hotkey, save, test, text].forEach(page.addSubview)
        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor), page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            cpu.0.leadingAnchor.constraint(equalTo: heading.leadingAnchor), cpu.0.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 28),
            disk.0.leadingAnchor.constraint(equalTo: heading.leadingAnchor), disk.0.topAnchor.constraint(equalTo: cpu.0.bottomAnchor, constant: 18),
            network.0.leadingAnchor.constraint(equalTo: heading.leadingAnchor), network.0.topAnchor.constraint(equalTo: disk.0.bottomAnchor, constant: 18),
            hotkeyLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor), hotkeyLabel.topAnchor.constraint(equalTo: network.0.bottomAnchor, constant: 22),
            hotkey.centerYAnchor.constraint(equalTo: hotkeyLabel.centerYAnchor), hotkey.leadingAnchor.constraint(equalTo: hotkeyLabel.trailingAnchor, constant: 24), hotkey.widthAnchor.constraint(equalToConstant: 150),
            save.leadingAnchor.constraint(equalTo: heading.leadingAnchor), save.topAnchor.constraint(equalTo: hotkeyLabel.bottomAnchor, constant: 22),
            test.leadingAnchor.constraint(equalTo: save.trailingAnchor, constant: 12), test.centerYAnchor.constraint(equalTo: save.centerYAnchor),
            text.leadingAnchor.constraint(equalTo: heading.leadingAnchor), text.topAnchor.constraint(equalTo: save.bottomAnchor, constant: 16), text.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36)
        ])
        mainScroll.documentView = page
    }

    private func numericSetting(title: String, key: String, fallback: Double) -> (NSView, NSTextField) {
        let row = NSView(); row.translatesAutoresizingMaskIntoConstraints = false
        let name = label(title, size: 13)
        let field = NSTextField(string: "\(UserDefaults.standard.object(forKey: key) == nil ? fallback : UserDefaults.standard.double(forKey: key))")
        field.translatesAutoresizingMaskIntoConstraints = false; field.alignment = .right
        row.addSubview(name); row.addSubview(field)
        NSLayoutConstraint.activate([row.widthAnchor.constraint(equalToConstant: 540), row.heightAnchor.constraint(equalToConstant: 34), name.leadingAnchor.constraint(equalTo: row.leadingAnchor), name.centerYAnchor.constraint(equalTo: row.centerYAnchor), field.trailingAnchor.constraint(equalTo: row.trailingAnchor), field.centerYAnchor.constraint(equalTo: row.centerYAnchor), field.widthAnchor.constraint(equalToConstant: 100)])
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
            let controller = Unmanaged<DashboardWindow>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { controller.showQuickSearch(); controller.window?.makeKeyAndOrderFront(nil) }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    private func detailPage(title: String, number: String, status: String, detail: String) -> NSView {
        let page = NSView(); page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("AI LOCK   /   \(number)", size: 10, color: lime, mono: true)
        let heading = label(title, size: 30, weight: .bold)
        let statusLabel = label(status, size: 14, weight: .semibold, color: NSColor.systemOrange)
        let body = NSTextField(wrappingLabelWithString: detail); body.font = .systemFont(ofSize: 12); body.textColor = muted; body.translatesAutoresizingMaskIntoConstraints = false
        [eyebrow, heading, statusLabel, body].forEach(page.addSubview)
        NSLayoutConstraint.activate([page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor), page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor), eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30), heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8), statusLabel.leadingAnchor.constraint(equalTo: heading.leadingAnchor), statusLabel.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 24), body.leadingAnchor.constraint(equalTo: heading.leadingAnchor), body.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -48), body.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 16)])
        return page
    }

    private func showProcesses() {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let eyebrow = label("PROCESS ACTIVITY   /   03", size: 10, color: lime, mono: true)
        let heading = label("进程管理", size: 30, weight: .bold)
        let subtitle = label("本机进程资源占用 · 正常退出优先 · 系统关键进程受保护", size: 12, color: muted)
        let search = NSSearchField()
        search.placeholderString = "搜索进程名或可执行路径"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = self
        search.action = #selector(processFilterChanged(_:))
        let sort = NSPopUpButton()
        sort.translatesAutoresizingMaskIntoConstraints = false
        ProcessSort.allCases.forEach { sort.addItem(withTitle: "按\($0.rawValue)排序") }
        sort.target = self
        sort.action = #selector(processFilterChanged(_:))
        let refresh = toolbarButton("刷新", symbol: "arrow.clockwise", action: #selector(refreshProcesses(_:)))
        let terminate = toolbarButton("正常退出", symbol: "xmark.circle", action: #selector(requestTerminateProcess(_:)))
        terminate.isEnabled = false
        let force = toolbarButton("强制结束…", symbol: "exclamationmark.octagon", action: #selector(requestForceTerminateProcess(_:)))
        force.isEnabled = false
        let actions = NSStackView(views: [refresh, terminate, force])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.spacing = 8

        let table = NSTableView()
        table.rowHeight = 38
        table.backgroundColor = cardColor
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .regular
        let columns: [(String, String, CGFloat)] = [("name", "进程", 180), ("pid", "PID", 72), ("cpu", "CPU", 84), ("memory", "内存", 104), ("path", "可执行文件", 400), ("status", "状态", 90)]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        let source = ProcessTableDataSource(entries: [])
        table.dataSource = source
        table.delegate = source
        table.target = self
        table.action = #selector(processSelectionChanged(_:))
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let status = label("正在读取进程…", size: 11, color: muted)
        [eyebrow, heading, subtitle, search, sort, actions, scroll, status].forEach(page.addSubview)

        NSLayoutConstraint.activate([
            page.widthAnchor.constraint(equalTo: mainScroll.contentView.widthAnchor), page.heightAnchor.constraint(equalTo: mainContainer.heightAnchor),
            eyebrow.leadingAnchor.constraint(equalTo: page.leadingAnchor, constant: 36), eyebrow.topAnchor.constraint(equalTo: page.topAnchor, constant: 30),
            heading.leadingAnchor.constraint(equalTo: eyebrow.leadingAnchor), heading.topAnchor.constraint(equalTo: eyebrow.bottomAnchor, constant: 8),
            subtitle.leadingAnchor.constraint(equalTo: heading.leadingAnchor), subtitle.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 6),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor), search.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 22), search.widthAnchor.constraint(equalToConstant: 270),
            sort.leadingAnchor.constraint(equalTo: search.trailingAnchor, constant: 10), sort.centerYAnchor.constraint(equalTo: search.centerYAnchor), sort.widthAnchor.constraint(equalToConstant: 132),
            actions.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), actions.centerYAnchor.constraint(equalTo: search.centerYAnchor),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: page.trailingAnchor, constant: -36), scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 16), scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -12),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor), status.bottomAnchor.constraint(equalTo: page.bottomAnchor, constant: -24)
        ])
        processTable = table
        processSearchField = search
        processSortPopup = sort
        processStatusLabel = status
        terminateButton = terminate
        forceTerminateButton = force
        processTableDataSource = source
        mainScroll.documentView = page
        refreshProcesses(nil)
        processTimer?.invalidate()
        processTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self, self.currentSection == 2 else { return }
            self.refreshProcesses(nil)
        }
    }

    @objc private func refreshProcesses(_ sender: Any?) {
        processEntries = processMonitor.sample()
        updateProcessTable()
        processStatusLabel?.stringValue = "\(processEntries.count) 个可见进程 · 每 2 秒刷新 · 部分系统进程信息受 macOS 隐私保护"
    }

    private func filteredProcesses() -> [MonitoredProcess] {
        let query = processSearchField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sort = ProcessSort.allCases.first { "按\($0.rawValue)排序" == processSortPopup?.titleOfSelectedItem } ?? .cpu
        let filtered = processEntries.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.executablePath.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .cpu: return filtered.sorted { $0.cpuPercent > $1.cpuPercent }
        case .memory: return filtered.sorted { $0.memoryBytes > $1.memoryBytes }
        case .name: return filtered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private func updateProcessTable() {
        processTableDataSource?.entries = filteredProcesses()
        processTable?.reloadData()
        guard let table = processTable, table.selectedRow >= 0,
              let entries = processTableDataSource?.entries, entries.indices.contains(table.selectedRow) else {
            terminateButton?.isEnabled = false
            forceTerminateButton?.isEnabled = false
            return
        }
        let canAct = !entries[table.selectedRow].isProtected
        terminateButton?.isEnabled = canAct
        forceTerminateButton?.isEnabled = canAct
    }

    @objc private func processFilterChanged(_ sender: Any?) { updateProcessTable() }

    @objc private func processSelectionChanged(_ sender: Any?) {
        guard let table = processTable, table.selectedRow >= 0,
              let entries = processTableDataSource?.entries, entries.indices.contains(table.selectedRow) else {
            terminateButton?.isEnabled = false
            forceTerminateButton?.isEnabled = false
            return
        }
        let canAct = !entries[table.selectedRow].isProtected
        terminateButton?.isEnabled = canAct
        forceTerminateButton?.isEnabled = canAct
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
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            guard kill(process.pid, SIGKILL) == 0 else {
                self?.showProcessResult("强制结束失败：\(String(cString: strerror(errno)))")
                return
            }
            self?.showProcessResult("已向 \(process.name)（PID \(process.pid)）发送强制终止信号。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refreshProcesses(nil) }
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

private final class LogTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [SystemLogEntry]

    init(entries: [SystemLogEntry]) { self.entries = entries }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let identifier = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let cell = NSTextField(wrappingLabelWithString: "")
        cell.font = .systemFont(ofSize: 11)
        cell.textColor = identifier == "level" ? color(for: entry.level) : ink
        cell.maximumNumberOfLines = identifier == "message" ? 2 : 1
        switch identifier {
        case "time": cell.stringValue = entry.formattedTime
        case "level": cell.stringValue = entry.level.rawValue
        case "process": cell.stringValue = entry.process
        case "message": cell.stringValue = entry.message
        default: return nil
        }
        return cell
    }

    private func color(for level: SystemLogLevel) -> NSColor {
        switch level {
        case .fault, .error: return .systemOrange
        case .debug: return muted
        default: return lime
        }
    }
}

private final class ProcessTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var entries: [MonitoredProcess]
    init(entries: [MonitoredProcess]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let process = entries[row]
        let cell = NSTextField(wrappingLabelWithString: "")
        cell.font = .systemFont(ofSize: 11)
        cell.textColor = column == "status" && process.isProtected ? muted : ink
        cell.lineBreakMode = column == "path" ? .byTruncatingMiddle : .byTruncatingTail
        switch column {
        case "name": cell.stringValue = process.name
        case "pid": cell.stringValue = String(process.pid)
        case "cpu": cell.stringValue = String(format: "%.1f%%", process.cpuPercent)
        case "memory": cell.stringValue = formattedBytes(process.memoryBytes)
        case "path": cell.stringValue = process.executablePath.isEmpty ? "（路径不可见）" : process.executablePath
        case "status": cell.stringValue = process.isProtected ? "系统保护" : "可管理"
        default: return nil
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let table = notification.object as? NSTableView else { return }
        NotificationCenter.default.post(name: .processSelectionChanged, object: table)
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
        cell.font = .systemFont(ofSize: 11); cell.textColor = ink
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

private final class ClipboardTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var records: [ClipboardRecord]
    private let formatter = DateFormatter()
    init(records: [ClipboardRecord]) {
        self.records = records
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    }
    func numberOfRows(in tableView: NSTableView) -> Int { records.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let record = records[row]
        let cell = NSTextField(wrappingLabelWithString: "")
        cell.font = .systemFont(ofSize: 11); cell.textColor = ink
        cell.lineBreakMode = column == "preview" ? .byTruncatingTail : .byTruncatingMiddle
        switch column {
        case "time": cell.stringValue = formatter.string(from: record.capturedAt)
        case "preview": cell.stringValue = record.preview
        case "source": cell.stringValue = record.sourceBundleID.isEmpty ? "未知应用" : record.sourceBundleID
        case "types": cell.stringValue = record.types.map { NSPasteboard.PasteboardType($0).rawValue.components(separatedBy: ".").last ?? $0 }.joined(separator: ", ")
        default: return nil
        }
        return cell
    }
}

private final class NetworkTableDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let entries: [NetworkConnection]
    init(entries: [NetworkConnection]) { self.entries = entries }
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row), let column = tableColumn?.identifier.rawValue else { return nil }
        let entry = entries[row]
        let cell = NSTextField(wrappingLabelWithString: "")
        cell.font = .systemFont(ofSize: 11); cell.textColor = ink
        switch column {
        case "protocol": cell.stringValue = entry.protocolName
        case "process": cell.stringValue = entry.process
        case "local": cell.stringValue = entry.local
        case "remote": cell.stringValue = entry.remote
        case "state": cell.stringValue = entry.state
        default: return nil
        }
        return cell
    }
}

private extension Notification.Name {
    static let processSelectionChanged = Notification.Name("AILockProcessSelectionChanged")
}

private final class CPUChartView: NSView {
    var samples: [(Date, Double)] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = bounds.insetBy(dx: 8, dy: 8)
        context.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.07).cgColor)
        context.setLineWidth(1)
        for fraction in [0.25, 0.5, 0.75, 1.0] {
            let y = bounds.minY + bounds.height * fraction
            context.move(to: CGPoint(x: bounds.minX, y: y)); context.addLine(to: CGPoint(x: bounds.maxX, y: y))
        }
        context.strokePath()
        guard samples.count > 1 else { return }
        let points = samples.enumerated().map { index, sample in
            CGPoint(x: bounds.minX + bounds.width * CGFloat(index) / CGFloat(max(samples.count - 1, 1)),
                    y: bounds.minY + bounds.height * CGFloat(min(max(sample.1 / 100, 0), 1)))
        }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: points[0].x, y: bounds.minY))
        path.addLine(to: points[0])
        for point in points.dropFirst() { path.addLine(to: point) }
        path.addLine(to: CGPoint(x: points.last!.x, y: bounds.minY))
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(lime.withAlphaComponent(0.12).cgColor)
        context.fillPath()
        let line = CGMutablePath(); line.move(to: points[0]); for point in points.dropFirst() { line.addLine(to: point) }
        context.addPath(line); context.setStrokeColor(lime.cgColor); context.setLineWidth(2); context.strokePath()
    }
}
