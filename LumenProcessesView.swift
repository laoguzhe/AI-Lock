import AppKit
import Darwin
import SwiftUI

// ============================================================================
//  进程管理
//  采样逻辑、身份复核、批量关闭流程与原实现保持一致；
//  视图层完全重写为 SwiftUI。
// ============================================================================

@MainActor
final class ProcessesModel: ObservableObject {
    @Published private(set) var entries: [MonitoredProcess] = []
    @Published private(set) var status: String = "正在读取进程…"
    @Published var search = ""
    @Published var sortKey: ProcessSort = .cpu
    @Published var ascending = false
    @Published var selection: pid_t?
    @Published var busyClosing = false

    enum ProcessSort: String, CaseIterable {
        case cpu, memory, network
        var title: String {
            switch self {
            case .cpu: return "处理器"
            case .memory: return "内存"
            case .network: return "网络"
            }
        }
    }

    private let monitor = ProcessMonitor()
    private let netMonitor = ProcessNetworkMonitor()
    private var timer: Timer?
    private var generation = 0
    private var sampling = false
    private let queue = DispatchQueue(label: "com.laogu.ailock.process-page", qos: .utility)

    // ---------------------------------------------------------------- 生命周期

    func start() {
        stop()
        netMonitor.start()
        refresh()
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        netMonitor.stop()
        sampling = false
    }

    // ---------------------------------------------------------------- 采样

    func refresh() {
        guard !sampling else { return }
        sampling = true
        let request = generation
        let processMonitor = monitor
        let processNetworkMonitor = netMonitor
        queue.async { [weak self, processMonitor, processNetworkMonitor] in
            var result = processMonitor.sample()
            var portFailure: String?
            let ports: [pid_t: [Int]]
            do {
                ports = try NetworkObservationService.shared.observation(maxAge: 15).listeningPorts(for: result)
            } catch {
                ports = [:]
                portFailure = error.localizedDescription
            }
            let rates = processNetworkMonitor.currentRates()
            for index in result.indices {
                let pid = result[index].pid
                result[index].ports = ports[pid] ?? []
                if let rate = rates[pid] {
                    result[index].networkDown = rate.down
                    result[index].networkUp = rate.up
                }
            }
            let updated = result
            let failure = portFailure
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.generation else { return }
                self.sampling = false
                self.entries = updated
                self.reportBadge()
                if !self.busyClosing {
                    self.status = UnitFormat.joined([
                        L10n.format("%{0} 个可见进程", arguments: [String(describing: updated.count)]),
                        failure.map { L10n.format("端口采样失败：%{0}", arguments: [String(describing: $0)]) } ?? ""
                    ])
                }
            }
        }
    }

    private func reportBadge() {
        ModuleBadgeCenter.shared.report(.processes, entries.count)
    }

    // ---------------------------------------------------------------- 过滤排序

    var visible: [MonitoredProcess] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? entries : entries.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.executablePath.localizedCaseInsensitiveContains(query)
                || $0.ports.contains { String($0).contains(query) }
        }
        switch sortKey {
        case .cpu:
            return filtered.sorted { ascending ? $0.cpuPercent < $1.cpuPercent : $0.cpuPercent > $1.cpuPercent }
        case .memory:
            return filtered.sorted { ascending ? $0.memoryBytes < $1.memoryBytes : $0.memoryBytes > $1.memoryBytes }
        case .network:
            return filtered.sorted {
                let left = $0.networkDown + $0.networkUp
                let right = $1.networkDown + $1.networkUp
                return ascending ? left < right : left > right
            }
        }
    }

    var selected: MonitoredProcess? {
        guard let selection else { return nil }
        return entries.first { $0.pid == selection }
    }

    var cpuTotal: Double { entries.reduce(0) { $0 + $1.cpuPercent } }
    var memoryTotal: UInt64 { entries.reduce(0) { $0 + $1.memoryBytes } }

    // ---------------------------------------------------------------- 操作

    func terminateSelected() {
        guard let process = selected, ProcessMonitor.canSignal(process) else {
            status = "进程身份已改变、已结束或受到保护，请刷新后重试。"
            return
        }
        guard let app = NSRunningApplication(processIdentifier: process.pid) else {
            status = "无法向该进程发送正常退出请求；可能是后台进程或进程已结束。"
            return
        }
        if app.terminate() {
            status = "已向 \(process.name) 发送正常退出请求。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.refresh() }
        } else {
            status = "正常退出请求未被接受。若确需结束，请单独确认强制结束。"
        }
    }

    /// 强制结束前必须再次核对进程身份，避免 PID 复用导致误杀。
    func confirmForceTerminate() {
        guard let process = selected, ProcessMonitor.canSignal(process) else {
            status = "进程身份已改变、已结束或受到保护，请刷新后重试。"
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.format("强制结束 %{0}？", arguments: [String(describing: process.name)])
        alert.informativeText = L10n.format(
            "PID %{0} 将被立即终止。未保存的数据可能丢失；系统服务或其他用户进程也可能无法由当前用户结束。",
            arguments: [String(describing: process.pid)])
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("强制结束"))
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            guard ProcessMonitor.canSignal(process) else {
                self?.status = "进程身份已改变、已结束或受到保护，未发送信号。"
                return
            }
            guard kill(process.pid, SIGKILL) == 0 else {
                self?.status = "强制结束失败：\(String(cString: strerror(errno)))"
                return
            }
            self?.status = "已向 \(process.name)（PID \(process.pid)）发送强制终止信号。"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refresh() }
        }
    }

    /// 批量结束：先列出清单让用户确认，再请求终止、3 秒后强制结束残留。
    func requestCloseUserProcesses() {
        guard !busyClosing else { return }
        busyClosing = true
        status = "正在读取将关闭的进程…"
        queue.async { [weak self] in
            let targets = ProcessBulkCloser.targets(in: ProcessMonitor().sample())
            DispatchQueue.main.async { [weak self] in
                self?.confirmClose(targets)
            }
        }
    }

    private func confirmClose(_ targets: [MonitoredProcess]) {
        guard !targets.isEmpty else {
            busyClosing = false
            status = "没有可关闭的非系统进程。"
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.format("关闭这 %{0} 个非系统进程？", arguments: [String(describing: targets.count)])
        alert.informativeText = L10n.text("将关闭下列当前账户的应用、后台进程、辅助进程及命令行任务。请先保存工作，未保存的数据可能丢失。先请求终止，3 秒后强制结束仍在运行的进程。系统进程、其他账户进程及 AI Lock 自身会保留；部分服务可能自动重启。只关闭本次清单中的进程。")
        alert.accessoryView = Self.listView(targets.map(describe).joined(separator: "\n\n"))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("确认关闭"))
        alert.buttons.last?.hasDestructiveAction = true
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else {
            busyClosing = false
            return
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            guard response == .alertSecondButtonReturn else {
                self.busyClosing = false
                self.status = "已取消，未关闭任何进程。"
                return
            }
            self.closeUserProcesses(targets)
        }
    }

    private func closeUserProcesses(_ targets: [MonitoredProcess]) {
        status = "正在关闭 \(targets.count) 个非系统进程…"
        netMonitor.stop()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let results = ProcessBulkCloser.close(targets)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busyClosing = false
                if self.timer != nil { self.netMonitor.start() }
                self.refresh()
                let closed = results.filter { $0.exited }.count
                let summary = "已结束 \(closed) 个，未关闭或无法核实 \(results.count - closed) 个。"
                self.status = summary
                let alert = NSAlert()
                alert.messageText = L10n.text("进程关闭结果")
                alert.informativeText = L10n.text(summary + L10n.text(" 系统可能重新启动部分后台服务。"))
                alert.accessoryView = Self.listView(results.map {
                    "\($0.message) · \(self.describe($0.process))"
                }.joined(separator: "\n\n"))
                alert.addButton(withTitle: L10n.text("完成"))
                if let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) {
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    private func describe(_ process: MonitoredProcess) -> String {
        let appName = NSRunningApplication(processIdentifier: process.pid)?.localizedName
        let name = appName.map { $0 == process.name ? $0 : "\($0) · \(process.name)" } ?? process.name
        return "\(name)  ·  PID \(process.pid)\n\(process.executablePath)"
    }

    static func listView(_ content: String) -> NSScrollView {
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

    func revealInFinder() {
        guard let process = selected, !process.executablePath.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: process.executablePath)])
    }
}

// ============================================================================
// MARK: - 视图
// ============================================================================

struct LumenProcessesView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @StateObject private var model = ProcessesModel()

    private static let columns: [ColumnSpec] = [
        .flex("进程", min: 150, ideal: 190),
        .fixed("PID", 66, alignment: .trailing, numeric: true),
        .fixed("处理器", 78, alignment: .trailing, numeric: true),
        .fixed("内存", 92, alignment: .trailing, numeric: true),
        .fixed("网络", 128, alignment: .trailing, numeric: true),
        .flex("端口", min: 110, ideal: 150),
        .flex("可执行文件", min: 160, ideal: 320),
        .fixed("状态", 76)
    ]

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .processes,
            subtitle: subtitle,
            trailing: { headerActions },
            footer: { footer },
            content: { table }
        )
        .onAppear { model.start() }
        .onDisappear { model.stop() }
        .moduleActivity(module: .processes,
                        onResume: { model.start() },
                        onSuspend: { model.stop() })
    }

    private var subtitle: String {
        UnitFormat.joined([
            L10n.text(model.status),
            L10n.format("已按%{0} · %{1}排序", arguments: [
                L10n.text(model.sortKey.title),
                L10n.text(model.ascending ? "升序" : "降序")
            ])
        ])
    }

    @ViewBuilder
    private var headerActions: some View {
        Button(L10n.text("结束所选")) { model.terminateSelected() }
            .lumenButton(.secondary, icon: "xmark.octagon")
            .disabled(model.selected == nil || model.selected?.isProtected == true)
        Button(L10n.text("关闭非系统进程")) { model.requestCloseUserProcesses() }
            .lumenButton(.secondary, icon: "power")
            .disabled(model.busyClosing)
    }

    private var toolbar: some View {
        ModuleToolbar {
            SearchBox(placeholder: "进程 / 路径 / 端口", text: $model.search, width: 220)
            SegmentedBar(
                options: ProcessesModel.ProcessSort.allCases.map { ($0.title, $0) },
                selection: Binding(
                    get: { model.sortKey },
                    set: { newValue in
                        if model.sortKey == newValue { model.ascending.toggle() } else { model.sortKey = newValue; model.ascending = false }
                    }
                )
            )
            Spacer(minLength: 8)
            if let selected = model.selected {
                Text(L10n.format("已选 %{0}", arguments: [selected.name]))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
            IconAction(symbol: "arrow.clockwise", help: "立即刷新") { model.refresh() }
        }
    }

    private var table: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    GridHeaderRow(columns: Self.columns)
                    ForEach(model.visible) { process in
                        ProcessRow(
                            process: process,
                            columns: Self.columns,
                            selected: model.selection == process.pid,
                            onSelect: { model.selection = process.pid },
                            onOpen: { model.revealInFinder() },
                            onTerminate: { model.selection = process.pid; model.terminateSelected() },
                            onForce: { model.selection = process.pid; model.confirmForceTerminate() }
                        )
                    }
                    if model.visible.isEmpty {
                        EmptyState(symbol: "cpu",
                                   title: model.entries.isEmpty ? "正在读取进程…" : "没有匹配的进程",
                                   detail: model.entries.isEmpty ? nil : "换个关键词，或清空搜索条件。")
                            .frame(height: 220)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Lumen.Palette.canvas)
        }
    }

    private var footer: some View {
        PageFooter(
            leading: model.status,
            tone: .active,
            trailing: [
                "\(model.entries.count) 个进程",
                "合计处理器 \(String(format: "%.1f", model.cpuTotal))%",
                "合计内存 \(UnitFormat.bytes(model.memoryTotal))"
            ]
        )
    }
}

// ============================================================================
// MARK: - 行
// ============================================================================

private struct GridHeaderRow: View {
    let columns: [ColumnSpec]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(L10n.text(column.title))
                    .microLabel()
                    .frame(maxWidth: column.isFlexible ? .infinity : nil, alignment: column.alignment)
                    .frame(width: column.fixedWidth, alignment: column.alignment)
                    .padding(.horizontal, 10)
            }
        }
        .frame(height: 26)
        .hairlineBottom()
        .background(Lumen.Palette.canvas)
    }
}

private extension ColumnSpec {
    var isFlexible: Bool { if case .flexible = width { return true }; return false }
    var fixedWidth: CGFloat? { if case .fixed(let w) = width { return w }; return nil }
}

private struct ProcessRow: View {
    let process: MonitoredProcess
    let columns: [ColumnSpec]
    let selected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void
    let onTerminate: () -> Void
    let onForce: () -> Void

    private var canAct: Bool { !process.isProtected }
    private var networkTotal: Double { process.networkDown + process.networkUp }

    var body: some View {
        GridRow(selected: selected, onTap: onSelect, onDoubleTap: onOpen) {
            HStack(spacing: 0) {
                // 进程名 + 图标
                HStack(spacing: 9) {
                    AppGlyph(name: process.name, image: icon, size: 20)
                    Text(process.name)
                        .font(Lumen.Typo.dense())
                        .foregroundStyle(Lumen.Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                numericCell(String(process.pid), width: 66, tone: Lumen.Palette.textMuted)
                numericCell(String(format: "%.1f%%", process.cpuPercent), width: 78,
                            tone: process.cpuPercent >= 50 ? Lumen.Palette.cautionInk : Lumen.Palette.text)
                numericCell(UnitFormat.bytes(process.memoryBytes), width: 92)

                // 网络列：上下行分别给数值与单位
                HStack(spacing: 0) {
                    if networkTotal > 0 {
                        HStack(spacing: 3) {
                            Text("↓").font(.system(size: 9, weight: .bold)).foregroundStyle(Lumen.Palette.downlink)
                            MonoText(text: UnitFormat.rateParts(process.networkDown).value, size: 10.5)
                            Text("↑").font(.system(size: 9, weight: .bold)).foregroundStyle(Lumen.Palette.activeInk)
                            MonoText(text: UnitFormat.rateParts(process.networkUp).value, size: 10.5)
                        }
                    } else {
                        Text("—").font(Lumen.Typo.dense()).foregroundStyle(Lumen.Palette.textGhost)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(width: 128, alignment: .leading)

                // 端口
                HStack(spacing: 4) {
                    if process.ports.isEmpty {
                        Text("—").font(Lumen.Typo.dense()).foregroundStyle(Lumen.Palette.textGhost)
                    } else {
                        ForEach(process.ports.prefix(2), id: \.self) { port in
                            Text(":\(port)")
                                .font(Lumen.Typo.mono(10))
                                .foregroundStyle(Lumen.Palette.textMuted)
                        }
                        if process.ports.count > 2 {
                            Text("+\(process.ports.count - 2)")
                                .font(Lumen.Typo.mono(9.5))
                                .foregroundStyle(Lumen.Palette.textGhost)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                // 路径
                Text(process.executablePath.isEmpty ? "—" : process.executablePath)
                    .font(Lumen.Typo.mono(10))
                    .foregroundStyle(process.executablePath.isEmpty ? Lumen.Palette.textGhost : Lumen.Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // 状态
                Group {
                    if process.isProtected {
                        Pill("受保护", tone: .caution)
                    } else {
                        Pill("运行中", tone: .active)
                    }
                }
                .frame(width: 76, alignment: .leading)
                .padding(.horizontal, 10)
            }
        }
        .contextMenu {
            Button(L10n.text("在 Finder 中显示")) { onOpen() }
                .disabled(process.executablePath.isEmpty)
            Divider()
            Button(L10n.text("正常退出")) { onTerminate() }.disabled(!canAct)
            Button(L10n.text("强制结束…")) { onForce() }.disabled(!canAct)
        }
    }

    private func numericCell(_ text: String, width: CGFloat, tone: Color = Lumen.Palette.text) -> some View {
        HStack {
            Spacer(minLength: 0)
            MonoText(text: text, size: 11.5, color: tone)
        }
        .padding(.horizontal, 10)
        .frame(width: width)
    }

    private var icon: NSImage? {
        guard !process.executablePath.isEmpty else { return nil }
        return NSWorkspace.shared.icon(forFile: process.executablePath)
    }
}
