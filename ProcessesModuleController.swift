import AppKit
import Darwin

final class ProcessesModuleController: ModuleViewController, NSMenuDelegate {
    private let processMonitor = ProcessMonitor()
    private let processNetworkMonitor = ProcessNetworkMonitor()
    private var processTimer: Timer?
    private var processEntries: [MonitoredProcess] = []
    private weak var processTable: NSTableView?
    private weak var processSearchField: NSSearchField?
    private weak var processStatusLabel: NSTextField?
    private weak var closeProcessesButton: NSButton?
    private var bulkCloseInProgress = false
    private var processTableDataSource: ProcessTableDataSource?
    private lazy var processContextMenu: NSMenu = {
        let menu = NSMenu()
        menu.delegate = self
        let terminate = NSMenuItem(title: L10n.text("正常退出"), action: #selector(requestTerminateProcess(_:)), keyEquivalent: "")
        terminate.target = self
        let force = NSMenuItem(title: L10n.text("强制结束…"), action: #selector(requestForceTerminateProcess(_:)), keyEquivalent: "")
        force.target = self
        menu.addItem(terminate)
        menu.addItem(force)
        return menu
    }()

    private var samplingGeneration = 0
    private var processRefreshInProgress = false
    private let samplingQueue = DispatchQueue(label: "com.laogu.ailock.process-page", qos: .utility)
    func stop() { samplingGeneration += 1; processTimer?.invalidate(); processTimer = nil; processNetworkMonitor.stop(); processRefreshInProgress = false }
    func resume() {
        stop(); processNetworkMonitor.start(); refreshProcesses(nil)
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.refreshProcesses(nil) }
        processTimer = timer; RunLoop.main.add(timer, forMode: .common)
    }
    deinit { processTimer?.invalidate(); processNetworkMonitor.stop() }
    override func loadView() {
        let page = NSView()
        page.translatesAutoresizingMaskIntoConstraints = false
        let search = NSSearchField()
        search.placeholderString = L10n.text("进程/路径/端口")
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
            column.title = L10n.text(title)
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
        scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let status = label("正在读取进程…", size: 11, color: muted)
        let closeUsers = toolbarButton("关闭非系统进程", symbol: "power", action: #selector(requestCloseUserProcesses(_:)))
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
        closeProcessesButton = closeUsers
        processTableDataSource = source
        view = page

    }

    @objc private func refreshProcesses(_ sender: Any?) {
        guard !processRefreshInProgress else { return }
        processRefreshInProgress = true
        let request = samplingGeneration
        samplingQueue.async { [weak self] in
            guard let self else { return }
            var entries = self.processMonitor.sample()
            var portError: String?
            let ports: [pid_t: [Int]]
            do { ports = try NetworkObservationService.shared.observation(maxAge: 15).listeningPorts(for: entries) }
            catch { ports = [:]; portError = error.localizedDescription }
            let rates = self.processNetworkMonitor.currentRates()
            for index in entries.indices {
                let pid = entries[index].pid
                entries[index].ports = ports[pid] ?? []
                if let rate = rates[pid] {
                    entries[index].networkDown = rate.down
                    entries[index].networkUp = rate.up
                }
            }
            let updated = entries
            let errorMessage = portError
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.samplingGeneration else { return }
                self.processRefreshInProgress = false
                self.processEntries = updated
                self.updateProcessTable()
                if !self.bulkCloseInProgress {
                    self.processStatusLabel?.stringValue = L10n.format("%{0} 个可见进程", arguments: [String(describing: updated.count)]) + (errorMessage.map { L10n.format(" · 端口采样失败：%{0}", arguments: [String(describing: $0)]) } ?? "")
                }
            }
        }
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
        guard let process = selectedProcess(), ProcessMonitor.canSignal(process) else { showProcessResult("进程身份已改变、已结束或受到保护，请刷新后重试。"); return }
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
        guard let process = selectedProcess(), ProcessMonitor.canSignal(process) else { showProcessResult("进程身份已改变、已结束或受到保护，请刷新后重试。"); return }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.format("强制结束 %{0}？", arguments: [String(describing: process.name)])
        alert.informativeText = L10n.format("PID %{0} 将被立即终止。未保存的数据可能丢失；系统服务或其他用户进程也可能无法由当前用户结束。", arguments: [String(describing: process.pid)])
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("强制结束"))
        guard let targetWindow = view.window else { return }
        alert.beginSheetModal(for: targetWindow) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            guard ProcessMonitor.canSignal(process) else {
                self?.showProcessResult("进程身份已改变、已结束或受到保护，未发送信号。")
                return
            }
            guard kill(process.pid, SIGKILL) == 0 else {
                self?.showProcessResult("强制结束失败：\(String(cString: strerror(errno)))")
                return
            }
            self?.showProcessResult("已向 \(process.name)（PID \(process.pid)）发送强制终止信号。")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refreshProcesses(nil) }
        }
    }

    @objc private func requestCloseUserProcesses(_ sender: Any?) {
        guard !bulkCloseInProgress, view.window != nil else { return }
        bulkCloseInProgress = true
        closeProcessesButton?.isEnabled = false
        showProcessResult("正在读取将关闭的进程…")
        samplingQueue.async { [weak self] in
            let targets = ProcessBulkCloser.targets(in: ProcessMonitor().sample())
            DispatchQueue.main.async { [weak self] in
                self?.confirmCloseProcesses(targets)
            }
        }
    }

    private func confirmCloseProcesses(_ targets: [MonitoredProcess]) {
        guard let targetWindow = view.window else { finishBulkClose(); return }
        guard !targets.isEmpty else {
            finishBulkClose()
            showProcessResult("没有可关闭的非系统进程。")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.format("关闭这 %{0} 个非系统进程？", arguments: [String(describing: targets.count)])
        alert.informativeText = L10n.text("将关闭下列当前账户的应用、后台进程、辅助进程及命令行任务。请先保存工作，未保存的数据可能丢失。先请求终止，3 秒后强制结束仍在运行的进程。系统进程、其他账户进程及 AI Lock 自身会保留；部分服务可能自动重启。只关闭本次清单中的进程。")
        alert.accessoryView = processListView(targets.map(processDescription).joined(separator: "\n\n"))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("确认关闭"))
        alert.buttons.last?.hasDestructiveAction = true
        alert.beginSheetModal(for: targetWindow) { [weak self] response in
            guard let self else { return }
            guard response == .alertSecondButtonReturn else {
                self.finishBulkClose()
                self.showProcessResult("已取消，未关闭任何进程。")
                return
            }
            self.closeUserProcesses(targets)
        }
    }

    private func processDescription(_ process: MonitoredProcess) -> String {
        let appName = NSRunningApplication(processIdentifier: process.pid)?.localizedName
        let name = appName.map { $0 == process.name ? $0 : "\($0) · \(process.name)" } ?? process.name
        return "\(name)  ·  PID \(process.pid)\n\(process.executablePath)"
    }

    private func processListView(_ content: String) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.font = .systemFont(ofSize: 12)
        text.textContainerInset = NSSize(width: 8, height: 8)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.bounds.width, height: .greatestFiniteMagnitude)
        text.string = content
        scroll.documentView = text
        return scroll
    }

    private func closeUserProcesses(_ targets: [MonitoredProcess]) {
        showProcessResult("正在关闭 \(targets.count) 个非系统进程…")
        processNetworkMonitor.stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = ProcessBulkCloser.close(targets)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.finishBulkClose()
                if self.processTimer != nil { self.processNetworkMonitor.start() }
                self.refreshProcesses(nil)
                let closed = results.filter { $0.exited }.count
                let summary = "已结束 \(closed) 个，未关闭或无法核实 \(results.count - closed) 个。"
                self.showProcessResult(summary)
                guard let window = self.view.window else { return }
                let alert = NSAlert()
                alert.messageText = L10n.text("进程关闭结果")
                alert.informativeText = L10n.text(summary + L10n.text(" 系统可能重新启动部分后台服务。"))
                alert.accessoryView = self.processListView(results.map {
                    "\($0.message) · \(self.processDescription($0.process))"
                }.joined(separator: "\n\n"))
                alert.addButton(withTitle: L10n.text("完成"))
                alert.beginSheetModal(for: window)
            }
        }
    }

    private func finishBulkClose() {
        bulkCloseInProgress = false
        closeProcessesButton?.isEnabled = true
    }

    private func selectedProcess() -> MonitoredProcess? {
        guard let table = processTable, table.selectedRow >= 0,
              let entries = processTableDataSource?.entries, entries.indices.contains(table.selectedRow) else { return nil }
        return entries[table.selectedRow]
    }

    private func showProcessResult(_ message: String) {
        processStatusLabel?.stringValue = L10n.text(message)
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
                imageView.widthAnchor.constraint(equalToConstant: 28),
                imageView.heightAnchor.constraint(equalToConstant: 28),
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
        let text = NSTextField(labelWithString: L10n.text(value))
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
