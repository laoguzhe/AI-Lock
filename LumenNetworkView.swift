import AppKit
import SwiftUI

// ============================================================================
//  网络活动
//  采样周期、基线语义、筛选与导出逻辑保持不变；
//  改用原生 SwiftUI 菜单与统一表格样式。
// ============================================================================

@MainActor
final class NetworkActivityPage: ObservableObject {
    @ObservedObject var model: NetworkActivityModel

    private let traffic = ProcessNetworkMonitor()
    private var timer: Timer?
    private var generation = 0
    private var inProgress = false
    private let queue = DispatchQueue(label: "com.laogu.ailock.network-page", qos: .utility)

    init(model: NetworkActivityModel) {
        self.model = model
    }

    func start() {
        stop()
        guard !model.paused else { return }
        traffic.start()
        refresh()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        generation += 1
        timer?.invalidate()
        timer = nil
        traffic.stop()
        inProgress = false
        model.sampling = false
        model.rates = [:]
        model.history.interrupt()
    }

    private func tick() {
        model.rates = traffic.currentRates()
        if let rate = model.rate(for: model.all) {
            model.appendTrafficSample(download: rate.down, upload: rate.up)
        }
        if model.sampledAt.map({ Date().timeIntervalSince($0) >= 5 }) ?? true { refresh() }
        // 让"新出现 / 状态变化"等基于时间的标记自动过期
        model.objectWillChange.send()
    }

    func togglePause() {
        model.paused.toggle()
        if model.paused { stop() } else { start() }
    }

    func refresh() {
        guard !inProgress, !model.paused else { return }
        inProgress = true
        model.sampling = true
        let request = generation
        queue.async { [weak self] in
            let result = Result { try NetworkObservationService.shared.observation(maxAge: 0) }
            DispatchQueue.main.async { [weak self] in
                guard let self, request == self.generation else { return }
                self.inProgress = false
                self.model.sampling = false
                switch result {
                case .success(let observation):
                    self.model.history.ingest(observation.connections, at: observation.sampledAt)
                    self.model.sampledAt = observation.sampledAt
                    self.model.status = "每 5 秒采样 · 已结束连接保留 30 秒 · 最近变化为 60 秒 · 历史最多 1,000 条"
                    ModuleBadgeCenter.shared.report(.network, observation.connections.count)
                case .failure(let error):
                    self.model.status = "采样失败，保留上次结果：\(error.localizedDescription)"
                }
            }
        }
    }

    var totalRate: (down: Double, up: Double)? { model.rate(for: model.all) }
}

// ============================================================================
// MARK: - 视图
// ============================================================================

struct LumenNetworkView: View {
    @StateObject private var model: NetworkActivityModel
    @StateObject private var page: NetworkActivityPage

    init() {
        let model = NetworkActivityModel()
        _model = StateObject(wrappedValue: model)
        _page = StateObject(wrappedValue: NetworkActivityPage(model: model))
    }

    private static let scopes = ["所有范围", "外网", "局域网", "本机", "多播", "监听", "未连接"]

    private static let columns: [ColumnSpec] = [
        .flex("应用", min: 140, ideal: 170),
        .fixed("协议", 62),
        .flex("远端 / 服务", min: 170, ideal: 220, numeric: false),
        .flex("本地地址", min: 140, ideal: 170, numeric: false),
        .fixed("状态", 92),
        .fixed("变化", 84),
        .fixed("范围", 66),
        .fixed("观测时长", 88, alignment: .trailing, numeric: true)
    ]

    var body: some View {
        ModulePage(
            module: .network,
            subtitle: subtitle,
            trailing: { actions },
            footer: { footer },
            content: { body_content }
        )
        .onAppear { page.start() }
        .onDisappear { page.stop() }
        .moduleActivity(module: .network,
                        onResume: { page.start() },
                        onSuspend: { page.stop() })
    }

    private var subtitle: String { L10n.text(model.status) }

    @ViewBuilder
    private var actions: some View {
        Button(L10n.text(model.paused ? "继续采样" : "暂停采样")) { page.togglePause() }
            .lumenButton(.secondary, icon: model.paused ? "play" : "pause")
    }

    private var body_content: some View {
        VStack(spacing: 0) {
            summaryStrip
            toolbar
            table
        }
    }

    // ---------------------------------------------------------------- 概览

    private var summaryStrip: some View {
        let active = model.all.filter(\.active).count
        let listening = model.all.filter { $0.connection.state == "LISTEN" }.count
        let apps = Set(model.all.filter(\.active).map { $0.connection.process }).count
        let rate = page.totalRate

        return HStack(spacing: Lumen.Metrics.s3) {
            overviewTile("当前连接", "\(active)", symbol: "arrow.left.arrow.right")
            overviewTile("监听端口", "\(listening)", symbol: "dot.radiowaves.left.and.right")
            overviewTile("联网应用", "\(apps)", symbol: "app.badge")
            overviewTile("下行", rate.map { UnitFormat.rateParts($0.down).value } ?? "—",
                         unit: rate.map { UnitFormat.rateParts($0.down).unit }, symbol: "arrow.down", tone: Lumen.Palette.downlink)
            overviewTile("上行", rate.map { UnitFormat.rateParts($0.up).value } ?? "—",
                         unit: rate.map { UnitFormat.rateParts($0.up).unit }, symbol: "arrow.up", tone: Lumen.Palette.activeInk)
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .padding(.bottom, Lumen.Metrics.s3)
    }

    private func overviewTile(_ label: String, _ value: String, unit: String? = nil, symbol: String = "", tone: Color = Lumen.Palette.text) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if !symbol.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Lumen.Palette.textFaint)
                }
                MicroText(label)
            }
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                MonoText(text: value, size: 15, weight: .light, color: tone)
                if let unit {
                    Text(unit).font(.system(size: 9.5)).foregroundStyle(Lumen.Palette.textFaint)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenPanel()
    }

    // ---------------------------------------------------------------- 工具栏

    private var toolbar: some View {
        ModuleToolbar {
            SearchBox(placeholder: "应用 / 地址 / 端口", text: $model.search, width: 220)

            filterMenu

            Spacer(minLength: 8)

            if let rate = page.totalRate {
                HStack(spacing: 10) {
                    HStack(spacing: 3) {
                        Text("↓").font(.system(size: 10, weight: .bold)).foregroundStyle(Lumen.Palette.downlink)
                        MonoText(text: UnitFormat.rateParts(rate.down).value, size: 11, weight: .semibold)
                    }
                    HStack(spacing: 3) {
                        Text("↑").font(.system(size: 10, weight: .bold)).foregroundStyle(Lumen.Palette.activeInk)
                        MonoText(text: UnitFormat.rateParts(rate.up).value, size: 11, weight: .semibold)
                    }
                }
            }

            Button(L10n.text("导出")) { model.export() }
                .lumenButton(.secondary, icon: "square.and.arrow.up", compact: true)
                .disabled(model.visible.isEmpty)

            IconAction(symbol: model.grouped ? "list.bullet" : "rectangle.grid.1x2",
                       help: model.grouped ? "切换为平铺列表" : "按应用分组") {
                model.grouped.toggle()
            }
        }
    }

    private var activeFilterCount: Int {
        var count = 0
        if model.period != "当前连接" { count += 1 }
        if model.app != "所有应用" { count += 1 }
        if model.proto != "所有协议" { count += 1 }
        if model.scope != "所有范围" { count += 1 }
        if model.sort != "最近变化" { count += 1 }
        return count
    }

    private var filterMenu: some View {
        Menu {
            Picker(L10n.text("显示记录"), selection: $model.period) {
                ForEach(["当前连接", "最近变化", "全部记录"], id: \.self) { Text(L10n.text($0)).tag($0) }
            }
            Picker(L10n.text("应用"), selection: $model.app) {
                Text(L10n.text("所有应用")).tag("所有应用")
                ForEach(model.apps, id: \.self) { Text($0).tag($0) }
            }
            Picker(L10n.text("协议"), selection: $model.proto) {
                ForEach(["所有协议", "TCP", "UDP"], id: \.self) { Text(L10n.text($0)).tag($0) }
            }
            Picker(L10n.text("网络范围"), selection: $model.scope) {
                ForEach(Self.scopes, id: \.self) { Text(L10n.text($0)).tag($0) }
            }
            Picker(L10n.text("排序方式"), selection: $model.sort) {
                ForEach(["最近变化", "应用名称", "远端地址", "观测时长"], id: \.self) { Text(L10n.text($0)).tag($0) }
            }
            if activeFilterCount > 0 {
                Divider()
                Button(L10n.text("清除全部筛选")) {
                    model.period = "当前连接"
                    model.app = "所有应用"
                    model.proto = "所有协议"
                    model.scope = "所有范围"
                    model.sort = "最近变化"
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11, weight: .semibold))
                Text(L10n.text("筛选"))
                    .font(.system(size: 11.5 * Lumen.scale))
                if activeFilterCount > 0 {
                    Text("\(activeFilterCount)")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 15, height: 15)
                        .background(Lumen.Palette.active, in: Circle())
                }
            }
            .foregroundStyle(activeFilterCount > 0 ? Lumen.Palette.activeInk : Lumen.Palette.text)
            .padding(.horizontal, 11)
            .frame(height: Lumen.Metrics.hField)
            .background(Lumen.Palette.raised, in: RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous)
                .strokeBorder(activeFilterCount > 0 ? Lumen.Palette.active.opacity(0.35) : Lumen.Palette.hairlineHard, lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    // ---------------------------------------------------------------- 表格

    private var table: some View {
        Group {
            if model.grouped {
                groupedList
            } else {
                flatTable
            }
        }
    }

    private var flatTable: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                NetworkGridHeader(columns: Self.columns)
                ForEach(model.visible) { record in
                    NetworkRow(
                        record: record,
                        columns: Self.columns,
                        selected: model.selected == record.id,
                        onTap: { model.selected = record.id; model.detail = record }
                    )
                }
                if model.visible.isEmpty { emptyState }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }

    private var groupedList: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: Lumen.Metrics.s3) {
                ForEach(groupedApps, id: \.name) { group in
                    LumenPanel(group.name, code: "\(group.records.count)", padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(group.records) { record in
                                HStack(spacing: Lumen.Metrics.s3) {
                                    MonoText(text: record.connection.protocolName, size: 10, color: Lumen.Palette.textFaint)
                                        .frame(width: 42, alignment: .leading)
                                    Text(record.connection.remote)
                                        .font(Lumen.Typo.mono(11))
                                        .foregroundStyle(Lumen.Palette.text)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(L10n.text(record.service))
                                        .font(Lumen.Typo.caption())
                                        .foregroundStyle(Lumen.Palette.textFaint)
                                        .frame(width: 110, alignment: .leading)
                                    if record.active {
                                        Pill(record.change, tone: .active)
                                    } else {
                                        Pill("已结束", tone: .neutral)
                                    }
                                    MonoText(text: record.duration, size: 10.5, color: Lumen.Palette.textFaint)
                                        .frame(width: 80, alignment: .trailing)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 30)
                                .hairlineBottom()
                                .contentShape(Rectangle())
                                .onTapGesture { model.selected = record.id; model.detail = record }
                            }
                        }
                    }
                }
                if groupedApps.isEmpty { emptyState }
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s4)
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }

    private var groupedApps: [(name: String, records: [NetworkActivityRecord])] {
        Dictionary(grouping: model.visible, by: { $0.connection.process })
            .map { (name: $0.key, records: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var emptyState: some View {
        EmptyState(symbol: "network",
                   title: model.paused ? "采样已暂停" : "没有匹配的连接",
                   detail: model.paused ? "继续采样后会重新读取当前连接。" : "调整筛选条件，或等待下一次采样。",
                   action: model.paused ? (label: "继续采样", run: { page.togglePause() }) : nil)
            .frame(height: 260)
    }

    private var footer: some View {
        PageFooter(
            leading: model.paused ? "采样已暂停" : "采样中",
            tone: model.paused ? .caution : .active,
            trailing: [
                "\(model.visible.count) / \(model.all.count) 条",
                model.sampledAt.map { "\($0.formatted(date: .omitted, time: .standard)) 采样" } ?? "尚未采样"
            ]
        )
    }
}

// ============================================================================
// MARK: - 表格行
// ============================================================================

private struct NetworkGridHeader: View {
    let columns: [ColumnSpec]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(L10n.text(column.title))
                    .microLabel()
                    .frame(maxWidth: column.networkFlexible ? .infinity : nil, alignment: column.alignment)
                    .frame(width: column.networkFixed, alignment: column.alignment)
                    .padding(.horizontal, 10)
            }
        }
        .frame(height: 26)
        .hairlineBottom()
        .background(Lumen.Palette.canvas)
    }
}

private extension ColumnSpec {
    var networkFlexible: Bool { if case .flexible = width { return true }; return false }
    var networkFixed: CGFloat? { if case .fixed(let w) = width { return w }; return nil }
}

private struct NetworkRow: View {
    let record: NetworkActivityRecord
    let columns: [ColumnSpec]
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        GridRow(selected: selected, onTap: onTap) {
            HStack(spacing: 0) {
                // 应用
                HStack(spacing: 8) {
                    AppGlyph(name: record.connection.process, image: icon, size: 18)
                    Text(record.connection.process)
                        .font(Lumen.Typo.dense())
                        .foregroundStyle(Lumen.Palette.text)
                        .lineLimit(1)
                    MonoText(text: String(record.connection.pid), size: 9.5, color: Lumen.Palette.textGhost)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                cell(record.connection.protocolName, width: 62, mono: true, tone: Lumen.Palette.textMuted)

                // 远端 + 服务
                HStack(spacing: 6) {
                    Text(record.connection.remote)
                        .font(Lumen.Typo.mono(11))
                        .foregroundStyle(record.active ? Lumen.Palette.text : Lumen.Palette.textFaint)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if record.service != "—" {
                        Text(L10n.text(record.service))
                            .font(.system(size: 9.5))
                            .foregroundStyle(Lumen.Palette.textGhost)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                cell(record.connection.local, flexible: true, mono: true, tone: Lumen.Palette.textFaint)
                cell(record.connection.state, width: 92, tone: Lumen.Palette.textMuted)

                HStack {
                    if record.active {
                        Pill(record.change, tone: record.change == "新出现" ? .active : .neutral)
                    } else {
                        Pill("已结束", tone: .neutral)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(width: 84)

                cell(L10n.text(record.scope), width: 66, tone: Lumen.Palette.textMuted)

                HStack {
                    Spacer(minLength: 0)
                    MonoText(text: record.duration, size: 10.5, color: Lumen.Palette.textFaint)
                }
                .padding(.horizontal, 10)
                .frame(width: 88)
            }
            .opacity(record.active ? 1 : 0.55)
        }
        .contextMenu {
            Button(L10n.text("复制远端地址")) { copy(record.connection.remote) }
            Button(L10n.text("复制本地地址")) { copy(record.connection.local) }
            Divider()
            Button(L10n.text("查看详情")) { onTap() }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func cell(_ text: String, width: CGFloat? = nil, flexible: Bool = false, mono: Bool = false, tone: Color = Lumen.Palette.text) -> some View {
        HStack {
            if mono {
                MonoText(text: text, size: 10.5, color: tone).lineLimit(1)
            } else {
                Text(text).font(Lumen.Typo.dense()).foregroundStyle(tone).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: flexible ? nil : width)
        .frame(maxWidth: flexible ? .infinity : nil, alignment: .leading)
    }

    private var icon: NSImage? {
        NSRunningApplication(processIdentifier: record.connection.pid)?.icon
    }
}

// ============================================================================
// MARK: - 连接详情
// ============================================================================

struct NetworkConnectionDetailView: View {
    let record: NetworkActivityRecord
    let onClose: () -> Void

    @State private var reverseDNS: String?

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "连接详情",
                       eyebrow: "NET / CONNECTION",
                       subtitle: "\(record.connection.process) · PID \(record.connection.pid)") {
                Button(L10n.text("关闭")) { onClose() }
                    .lumenButton(.secondary)
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                    LumenPanel("连接", code: record.connection.protocolName) {
                        VStack(alignment: .leading, spacing: 3) {
                            DetailPair(key: "本地地址", value: record.connection.local, mono: true)
                            DetailPair(key: "远端地址", value: record.connection.remote, mono: true)
                            DetailPair(key: "状态", value: record.connection.state)
                            DetailPair(key: "服务", value: L10n.text(record.service))
                            DetailPair(key: "网络范围", value: L10n.text(record.scope))
                            if let reverseDNS {
                                DetailPair(key: "反向解析", value: reverseDNS, mono: true)
                            }
                        }
                    }

                    LumenPanel("观测", code: "SESSION") {
                        VStack(alignment: .leading, spacing: 3) {
                            DetailPair(key: "首次发现", value: record.firstSeen.formatted(date: .abbreviated, time: .standard))
                            DetailPair(key: "最后发现", value: record.lastSeen.formatted(date: .abbreviated, time: .standard))
                            DetailPair(key: "观测时长", value: record.duration)
                            DetailPair(key: "当前状态", value: record.active ? "活动" : "已结束")
                        }
                    }

                    LumenPanel("变化记录", code: "\(record.changes.count)", padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(record.changes.enumerated()), id: \.offset) { _, change in
                                MonoText(text: change, size: 10.5, color: Lumen.Palette.textMuted)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 6)
                                    .hairlineBottom()
                            }
                        }
                    }

                    if reverseDNS == nil {
                        Button(L10n.text("反向解析远端地址")) {
                            reverseDNS = NetworkEndpoint.resolve(record.connection.remote)
                        }
                        .lumenButton(.secondary, icon: "arrow.triangle.2.circlepath")
                    }
                }
                .padding(.horizontal, Lumen.Metrics.pageInset)
                .padding(.bottom, Lumen.Metrics.s5)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Lumen.Palette.canvas)
        .frame(width: 620, height: 520)
    }
}
