import AppKit
import SwiftUI

// ============================================================================
//  应用日志
//  读取、分页、筛选、分组与诊断导出的语义保持不变；
//  七段快筛改成带计数的状态标签，扫读成本更低。
// ============================================================================

@MainActor
final class LogsPageModel: ObservableObject {
    @Published var entries: [SystemLogEntry] = []
    @Published var groups: [SystemLogGroup] = []
    @Published var search = ""
    @Published var level: SystemLogLevel = .all
    @Published var quick: QuickFilter = .all
    @Published var status = "正在加载最近 10 分钟的应用与系统日志…"
    @Published var failed = false
    @Published var detail: SystemLogGroup?

    enum QuickFilter: String, CaseIterable {
        case all, attention, error, fault, notice, info, debug

        var title: String {
            switch self {
            case .all: return "全部"
            case .attention: return "需要处理"
            case .error: return "错误"
            case .fault: return "严重"
            case .notice: return "通知"
            case .info: return "信息"
            case .debug: return "调试"
            }
        }
    }

    private let store = SystemLogStore()
    private var generation = 0

    /// 先取原始数据，再按当前筛选条件派生分组 —— 与旧实现一致。
    private var filtered: [SystemLogEntry] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.filter { entry in
            (level == .all || entry.level == level)
                && matchesQuick(entry)
                && (query.isEmpty
                    || entry.summary.localizedCaseInsensitiveContains(query)
                    || entry.message.localizedCaseInsensitiveContains(query)
                    || entry.subsystem.localizedCaseInsensitiveContains(query)
                    || entry.category.localizedCaseInsensitiveContains(query)
                    || entry.process.localizedCaseInsensitiveContains(query))
        }
    }

    private func matchesQuick(_ entry: SystemLogEntry) -> Bool {
        switch quick {
        case .all: return true
        case .attention: return entry.needsAttention
        case .error: return entry.level == .error
        case .fault: return entry.level == .fault
        case .notice: return entry.level == .notice
        case .info: return entry.level == .info
        case .debug: return entry.level == .debug
        }
    }

    func count(for filter: QuickFilter) -> Int {
        switch filter {
        case .all: return entries.count
        case .attention: return entries.filter(\.needsAttention).count
        case .error: return entries.filter { $0.level == .error }.count
        case .fault: return entries.filter { $0.level == .fault }.count
        case .notice: return entries.filter { $0.level == .notice }.count
        case .info: return entries.filter { $0.level == .info }.count
        case .debug: return entries.filter { $0.level == .debug }.count
        }
    }

    func recompute() {
        let filteredEntries = filtered
        let merged = SystemLogGroup.merge(filteredEntries)
        groups = merged
        status = L10n.format("显示 %{0} 个事件 / %{1} 条记录 · 应用与系统最近 10 分钟（最多 2000 条）",
                             arguments: [String(merged.count), String(filteredEntries.count)])
        if level != .all { quick = .all }
        ModuleBadgeCenter.shared.report(.logs, merged.filter { $0.latest.needsAttention }.count)
    }

    func load() {
        generation += 1
        let request = generation
        entries = []
        groups = []
        failed = false
        status = "正在加载最近 10 分钟的应用与系统日志…"
        store.fetch(onBatch: { [weak self] batch, count, finished in
            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                if !batch.isEmpty {
                    // 新批次插到前面，保持时间倒序。
                    self.entries.insert(contentsOf: batch, at: 0)
                    if self.entries.count > 2_000 {
                        self.entries.removeLast(self.entries.count - 2_000)
                    }
                    self.recompute()
                }
                if finished {
                    self.status = L10n.format("已完成查询，共扫描 %{0} 条；保留 %{1} 条",
                                              arguments: [String(count), String(self.entries.count)])
                }
            }
        }) { [weak self] error in
            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                if let error {
                    self.entries = []
                    self.groups = []
                    self.failed = true
                    self.status = L10n.format("读取失败：%{0}", arguments: [String(error.localizedDescription)])
                } else {
                    self.recompute()
                }
            }
        }
    }

    func export() {
        let logs = "\(L10n.text("AI Lock 应用日志"))\n\(L10n.text("导出时间："))\(Date())\n"
            + "\(L10n.text("范围：当前筛选结果"))\n\(L10n.text("记录数："))\(filtered.count)\n"
            + filtered.sorted { $0.date < $1.date }.map { entry in
                LogDiagnosticReport.redact(
                    "\n[\(entry.formattedTime)] [\(entry.level.rawValue)] \(entry.process) / \(entry.subsystem) / \(entry.category)\n\(entry.message)\n"
                )
            }.joined()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "AI-Lock-logs.txt"
        panel.title = L10n.text("导出当前筛选的日志")
        panel.message = L10n.text("已隐藏常见敏感字段。导出日志后请检查内容再分享。")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try logs.write(to: url, atomically: true, encoding: .utf8)
            status = "日志已导出"
        } catch {
            status = "导出失败：\(error.localizedDescription)"
        }
    }

    func copyDetail(_ group: SystemLogGroup) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(group.detail, forType: .string)
        status = "已复制事件详情"
    }
}

// ============================================================================
// MARK: - 视图
// ============================================================================

struct LumenLogsView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @StateObject private var model = LogsPageModel()

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .logs,
            subtitle: model.status,
            trailing: { actions },
            footer: { footer },
            content: { content }
        )
        .onAppear { if model.entries.isEmpty { model.load() } }
        .sheet(item: Binding(
            get: { model.detail.map(LogDetailTarget.init) },
            set: { if $0 == nil { model.detail = nil } }
        )) { target in
            LogDetailSheet(group: target.group) {
                model.copyDetail(target.group)
                model.detail = nil
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        Button(L10n.text("重新加载")) { model.load() }
            .lumenButton(.secondary, icon: "arrow.clockwise")
        Button(L10n.text("导出日志")) { model.export() }
            .lumenButton(.secondary, icon: "square.and.arrow.up")
            .disabled(model.groups.isEmpty)
    }

    private var content: some View {
        VStack(spacing: 0) {
            toolbar
            table
        }
    }

    private var toolbar: some View {
        ModuleToolbar {
            SearchBox(placeholder: "搜索消息、子系统、类别或进程", text: Binding(
                get: { model.search },
                set: { model.search = $0; model.recompute() }
            ), width: 260)

            Picker("", selection: Binding(
                get: { model.level },
                set: { model.level = $0; model.quick = .all; model.recompute() }
            )) {
                ForEach(SystemLogLevel.allCases, id: \.self) { level in
                    Text(L10n.text(level.rawValue)).tag(level)
                }
            }
            .labelsHidden()
            .frame(width: 130)

            Spacer(minLength: Lumen.Metrics.s2)

            if model.failed {
                Pill("读取失败", tone: .danger, symbol: "exclamationmark.triangle")
            }
        }
    }

    private var quickFilters: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(LogsPageModel.QuickFilter.allCases, id: \.self) { filter in
                    let on = model.quick == filter
                    let count = model.count(for: filter)
                    Button {
                        model.quick = filter
                        model.level = .all
                        model.recompute()
                    } label: {
                        HStack(spacing: 5) {
                            Text(L10n.text(filter.title))
                                .font(.system(size: 11 * Lumen.scale, weight: on ? .semibold : .regular))
                            MonoText(text: "\(count)", size: 10,
                                     color: on ? Lumen.Palette.activeInk : Lumen.Palette.textGhost)
                        }
                        .foregroundStyle(on ? Lumen.Palette.activeInk : Lumen.Palette.textMuted)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(on ? Lumen.Palette.activeWash : Lumen.Palette.fill,
                                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(on ? Lumen.Palette.active.opacity(0.3) : Color.clear, lineWidth: 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(count == 0 && filter != .all)
                    .opacity(count == 0 && filter != .all ? 0.45 : 1)
                }
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s2)
        }
    }

    private static let columns: [ColumnSpec] = [
        .fixed("时间", 156, numeric: true),
        .fixed("级别", 74),
        .fixed("进程", 110),
        .flex("消息", min: 300, ideal: 620)
    ]

    private var table: some View {
        VStack(spacing: 0) {
            quickFilters
            HStack(spacing: 0) {
                ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                    Text(L10n.text(column.title))
                        .microLabel()
                        .padding(.horizontal, 10)
                        .frame(maxWidth: column.logFlexible ? .infinity : nil, alignment: column.alignment)
                        .frame(width: column.logFixed, alignment: column.alignment)
                }
            }
            .frame(height: 26)
            .hairlineBottom()

            if model.groups.isEmpty {
                EmptyState(symbol: "list.bullet.rectangle",
                           title: model.failed ? "读取失败" : (model.entries.isEmpty ? "正在加载日志…" : "没有匹配的事件"),
                           detail: model.failed ? "权限或系统状态可能阻止了读取，可尝试重新加载。"
                                                : (model.entries.isEmpty ? nil : "调整筛选条件或清空搜索。"),
                           action: model.failed ? (label: "重新加载", run: { model.load() }) : nil)
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 0) {
                        ForEach(model.groups, id: \.latest.id) { group in
                            LogGroupRow(group: group) { model.detail = group }
                        }
                    }
                }
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var footer: some View {
        PageFooter(
            leading: model.status,
            tone: model.failed ? .danger : .active,
            trailing: [
                "\(model.groups.count) 个事件",
                "\(model.entries.count) 条记录",
                "最近 10 分钟"
            ]
        )
    }
}

private extension ColumnSpec {
    var logFlexible: Bool { if case .flexible = width { return true }; return false }
    var logFixed: CGFloat? { if case .fixed(let w) = width { return w }; return nil }
}

// ============================================================================
// MARK: - 行
// ============================================================================

private struct LogGroupRow: View {
    let group: SystemLogGroup
    let onOpen: () -> Void

    private var entry: SystemLogEntry { group.latest }

    var body: some View {
        GridRow(onTap: onOpen, onDoubleTap: onOpen, fixedHeight: nil) {
            HStack(alignment: .top, spacing: 0) {
                MonoText(text: entry.formattedTime, size: 10.5, color: Lumen.Palette.textFaint)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .frame(width: 156, alignment: .leading)

                HStack {
                    Pill(entry.level.rawValue, tone: levelTone)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .frame(width: 74)

                Text(entry.process)
                    .font(Lumen.Typo.dense())
                    .foregroundStyle(Lumen.Palette.textMuted)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.top, 10)
                    .frame(width: 110, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(group.title)
                            .font(Lumen.Typo.dense())
                            .foregroundStyle(entry.needsAttention ? Lumen.Palette.cautionInk : Lumen.Palette.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        if entry.needsAttention {
                            Pill("需要处理", tone: .caution)
                        }
                    }
                    Text(UnitFormat.joined([entry.subsystem, entry.category]))
                        .font(Lumen.Typo.mono(9.5))
                        .foregroundStyle(Lumen.Palette.textGhost)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: Lumen.Metrics.hRow)
        }
        .contextMenu {
            Button(L10n.text("查看完整记录")) { onOpen() }
        }
    }

    private var levelTone: PillTone {
        switch entry.level {
        case .error, .fault: return .danger
        case .notice: return .caution
        case .all, .info, .debug: return .neutral
        }
    }
}

// ============================================================================
// MARK: - 详情
// ============================================================================

/// SystemLogGroup 不是 Identifiable，包一层给它一个稳定 id 以驱动 sheet。
struct LogDetailTarget: Identifiable {
    let group: SystemLogGroup
    var id: String { group.latest.id }
}

private struct LogDetailSheet: View {
    let group: SystemLogGroup
    let onCopy: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "运行记录详情",
                       eyebrow: "LOG / DETAIL",
                       subtitle: UnitFormat.joined([group.latest.process, group.latest.subsystem, group.latest.category])) {
                Button(L10n.text("复制消息")) { onCopy() }
                    .lumenButton(.secondary, icon: "doc.on.doc")
            }

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                    LumenPanel("概要", code: group.latest.level.rawValue) {
                        VStack(alignment: .leading, spacing: 3) {
                            DetailPair(key: "时间", value: group.latest.formattedTime, mono: true)
                            DetailPair(key: "进程", value: group.latest.process)
                            DetailPair(key: "子系统", value: group.latest.subsystem)
                            DetailPair(key: "类别", value: group.latest.category)
                            DetailPair(key: "重复次数", value: "\(group.entries.count)")
                        }
                    }

                    LumenPanel("原始记录", code: "RAW", padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(group.detail)
                                .font(Lumen.Typo.mono(11))
                                .foregroundStyle(Lumen.Palette.textMuted)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                        }
                    }

                    NoticeBar(level: .info, text: group.latest.guidance)
                }
                .padding(.horizontal, Lumen.Metrics.pageInset)
                .padding(.bottom, Lumen.Metrics.s5)
            }
            .scrollContentBackground(.hidden)
        }
        .frame(width: 660, height: 560)
        .background(Lumen.Palette.canvas)
    }
}
