import AppKit
import Darwin
import SwiftUI

// ============================================================================
//  安全活动（应用、网络与 Endpoint Security 文件审计）
//  筛选语义、导出字段、核实标记、免责说明全部保持原样；
//  布局改为「概览 → 筛选 → 表格 → 详情」的单一纵向流。
// ============================================================================

struct LumenFileActivityView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @ObservedObject private var audit = AuditExtensionClient.shared
    @ObservedObject private var extensions = SystemExtensionController.shared
    @ObservedObject private var aiUsage = AIUsageTracker.shared
    @ObservedObject private var agentHooks = AgentHookManager.shared
    @ObservedObject private var agentEvents = AgentHookStore.shared
    @StateObject private var activity = SecurityActivityMonitor()

    @State private var scope = "全部程序"
    @State private var operation = "全部操作"
    @State private var sensitiveOnly = false
    @State private var application = "全部应用"
    @State private var period = "最近 24 小时"
    @State private var unreviewedOnly = false
    @State private var confirmClear = false
    @State private var selected: UUID?
    @State private var paused = false
    @State private var frozen: [FileAuditRecord] = []
    @State private var exportError = ""
    @State private var showingNotes = false

    private var records: [FileAuditRecord] {
        (paused ? frozen : audit.events).filter {
            (scope != "AI 工具（推测）" || $0.isAI)
                && (!sensitiveOnly || $0.sensitiveReason != nil)
                && (application == "全部应用" || $0.executable == application)
                && (period == "全部历史" || $0.date >= Date().addingTimeInterval(period == "最近 1 小时" ? -3600 : -86400))
                && (!unreviewedOnly || !audit.reviewed.contains($0.id))
                && (operation == "全部操作"
                    || (operation == "打开 / 可能读取" && $0.kind == "open")
                    || (operation == "修改" && ($0.operation == "修改后关闭" || $0.kind == "write"))
                    || (operation == "创建" && $0.kind == "create")
                    || (operation == "删除" && $0.kind == "unlink")
                    || (operation == "移动" && $0.kind == "rename"))
        }
    }

    private var selectedRecord: FileAuditRecord? {
        records.first { $0.id == selected }
    }

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .files,
            subtitle: subtitle,
            trailing: { headerActions },
            footer: { footer },
            content: { content }
        )
        .alert(L10n.text("清空本地安全活动历史？"), isPresented: $confirmClear) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("清空历史"), role: .destructive) {
                audit.clearHistory()
                activity.clearHistory()
                agentEvents.clearHistory()
                frozen = []
                selected = nil
            }
        } message: {
            Text(L10n.text("删除本地事件和核实标记。采集会继续，已导出的文件不会删除。"))
        }
        .onAppear { ModuleBadgeCenter.shared.report(.files, audit.events.count) }
        .onAppear { activity.start() }
        .onDisappear { activity.stop() }
        .moduleActivity(module: .files,
                        onResume: { ModuleBadgeCenter.shared.report(.files, audit.events.count); activity.start() },
                        onSuspend: { activity.stop() })
    }

    private var subtitle: String {
        UnitFormat.joined([audit.status, audit.historyStatus])
    }

    @ViewBuilder
    private var headerActions: some View {
        Button(L10n.text(audit.active ? "停止文件审计" : "开始文件审计")) {
            if audit.active { audit.stop() } else { audit.start(root: URL(fileURLWithPath: "/")) }
        }
        .lumenButton(audit.active ? .secondary : .primary, icon: audit.active ? "stop.fill" : "play.fill")
        .disabled(audit.busy)

        Menu {
            Button(L10n.text(paused ? "继续显示" : "暂停显示")) {
                if !paused { frozen = audit.events }
                paused.toggle()
            }
            Button(L10n.text("导出 JSON…")) { exportRecords() }.disabled(records.isEmpty && activity.events.isEmpty && agentEvents.events.isEmpty)
            Button(L10n.text("清空历史…")) { confirmClear = true }.disabled(audit.events.isEmpty && activity.events.isEmpty && agentEvents.events.isEmpty)
            Divider()
            Button(L10n.text("查询审计扩展")) { extensions.queryAudit() }.disabled(extensions.busy)
            Button(L10n.text("安装 / 更新审计扩展")) { extensions.activateAudit() }.disabled(extensions.busy)
            Button(L10n.text("打开完全磁盘访问设置")) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
        } label: {
            Text(L10n.text("更多操作"))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .buttonStyle(LumenButtonStyle(kind: .secondary))
    }

    // ---------------------------------------------------------------- 内容

    private var content: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                aiBehaviorPanel
                activityPanel
                scopeSummary
                if !audit.active { inactiveNotice }
                if !audit.gaps.isEmpty { gapsNotice }
                filterPanel
                eventTable
                if let record = selectedRecord { detailPanel(record) }
                if !exportError.isEmpty {
                    NoticeBar(level: .danger, text: exportError)
                }
                notesDisclosure
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s5)
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }

    private var aiBehaviorPanel: some View {
        LumenPanel("AI 行为监视", code: "AGENT ACTIVITY") {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s2) {
                Text(L10n.text("通过本机 Agent 工具钩子记录调用时间、工具、命令和目标路径。风险提示只供人工核对，监视模式不会阻止操作；提示词和模型回复正文不会保存。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("接入时会先为对应 Agent 配置创建本地副本，再添加监视钩子；需要重启该 Agent 生效。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), alignment: .leading, spacing: 8) {
                    ForEach(AgentHookProvider.allCases) { provider in
                        let status = agentHooks.statuses[provider] ?? "未接入"
                        let monitoring = status.contains("仅监视已接入")
                        HStack(spacing: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.rawValue).font(.system(size: 11, weight: .semibold))
                                Text(L10n.text(status)).font(Lumen.Typo.caption()).foregroundStyle(Lumen.Palette.textFaint).lineLimit(1)
                            }
                            Spacer(minLength: 2)
                            Button(L10n.text(monitoring ? "移除" : (status.contains("AI Lock Hook 已接入") ? "切换为仅监视" : "接入监视"))) {
                                if monitoring { agentHooks.uninstall(provider) }
                                else { agentHooks.installMonitor(provider) }
                            }
                            .lumenButton(.secondary, compact: true)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Lumen.Palette.canvas, in: RoundedRectangle(cornerRadius: 7))
                    }
                }

                if agentEvents.events.isEmpty {
                    Text(L10n.text("尚无 AI 工具调用记录。选择上方接入后，重启对应 Agent；后续工具调用会出现在这里。"))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textFaint)
                        .padding(.vertical, 5)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(agentEvents.events.prefix(12)) { event in
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: event.reason.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(event.reason.isEmpty ? Lumen.Palette.activeInk : Lumen.Palette.cautionInk)
                                    .frame(width: 15)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(event.provider).font(.system(size: 11, weight: .semibold))
                                        Text("· \(event.tool) · \(event.outcome)")
                                            .font(Lumen.Typo.caption()).foregroundStyle(Lumen.Palette.textMuted)
                                        Spacer()
                                        Text(event.date.formatted(date: .omitted, time: .shortened))
                                            .font(Lumen.Typo.mono(10)).foregroundStyle(Lumen.Palette.textFaint)
                                    }
                                    if !event.reason.isEmpty {
                                        Text(L10n.text(event.reason)).font(Lumen.Typo.caption()).foregroundStyle(Lumen.Palette.cautionInk)
                                    }
                                    let target = !event.path.isEmpty ? event.path : event.command
                                    if !target.isEmpty {
                                        Text(target).font(Lumen.Typo.mono(10)).foregroundStyle(Lumen.Palette.textMuted)
                                            .lineLimit(2).textSelection(.enabled)
                                    }
                                    if !event.workingDirectory.isEmpty {
                                        Text("工作目录：\(event.workingDirectory)").font(Lumen.Typo.mono(9)).foregroundStyle(Lumen.Palette.textFaint)
                                            .lineLimit(1).textSelection(.enabled)
                                    }
                                }
                            }
                            .padding(.vertical, 6)
                            if event.id != agentEvents.events.prefix(12).last?.id {
                                Divider().overlay(Lumen.Palette.hairlineSoft)
                            }
                        }
                    }
                }
                NoticeBar(level: .info, text: "风险标签是基于命令片段、工具名称或敏感路径的启发式提示。工具钩子记录的是 Agent 发起的调用，不保证操作已经成功，也不涵盖未接入的程序；需和下方系统文件审计、进程网络活动交叉核实。")
            }
        }
    }

    private var activityPanel: some View {
        LumenPanel("应用与网络活动", code: "LIVE ACTIVITY") {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s2) {
                HStack(spacing: Lumen.Metrics.s2) {
                    Image(systemName: activity.isMonitoring ? "dot.radiowaves.left.and.right" : "pause.circle")
                        .foregroundStyle(activity.isMonitoring ? Lumen.Palette.activeInk : Lumen.Palette.cautionInk)
                    Text(L10n.text(activity.isMonitoring ? "正在观察应用启动与网络连接" : "监测已暂停"))
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text(L10n.format("%{0} 条活动", arguments: [String(activity.events.count)]))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textMuted)
                }

                if activity.events.isEmpty {
                    Text(L10n.text("打开应用或建立网络连接后，活动会显示在这里。"))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textMuted)
                        .padding(.vertical, 8)
                } else {
                    ForEach(activity.events.prefix(12)) { event in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: event.isWarning ? "exclamationmark.triangle.fill" : event.symbol)
                                .foregroundStyle(event.isWarning ? Lumen.Palette.cautionInk : Lumen.Palette.textFaint)
                                .frame(width: 15)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(L10n.text(event.title)).font(.system(size: 11, weight: .semibold))
                                    Text("· \(event.process) · PID \(event.pid)")
                                        .font(Lumen.Typo.caption()).foregroundStyle(Lumen.Palette.textMuted)
                                    Spacer()
                                    Text(event.date.formatted(date: .omitted, time: .shortened))
                                        .font(Lumen.Typo.mono(10)).foregroundStyle(Lumen.Palette.textFaint)
                                }
                                Text(event.detail).font(Lumen.Typo.caption()).foregroundStyle(Lumen.Palette.textMuted)
                                    .lineLimit(2).textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 5)
                        if event.id != activity.events.prefix(12).last?.id {
                            Divider().overlay(Lumen.Palette.hairlineSoft)
                        }
                    }
                }
                NoticeBar(level: .info, text: "此处显示当前模块开启期间观察到的应用启动和进程网络连接。新连接不等于恶意行为；风险标签仅按程序所在路径作启发式提示。网络数据是连接概况，不包含数据包内容。")
            }
        }
    }

    // ---------------------------------------------------------------- 概览

    private var scopeSummary: some View {
        HStack(spacing: Lumen.Metrics.s3) {
            tile("采集状态", audit.active ? "进行中" : "未采集",
                 tone: audit.active ? Lumen.Palette.activeInk : Lumen.Palette.cautionInk,
                 symbol: audit.active ? "record.circle" : "pause.circle")
            tile("事件总数", "\(audit.events.count)", symbol: "doc.text")
            tile("AI 敏感访问", "\(aiSensitiveCount)", tone: aiSensitiveCount > 0 ? Lumen.Palette.cautionInk : Lumen.Palette.text,
                 symbol: "exclamationmark.triangle")
            tile("待核实", "\(unreviewedCount)", tone: unreviewedCount > 0 ? Lumen.Palette.cautionInk : Lumen.Palette.text,
                 symbol: "checkmark.circle")
            tile("当前显示", "\(records.count) / \(audit.events.count)", symbol: "line.3.horizontal.decrease")
        }
    }

    private var aiSensitiveCount: Int {
        audit.events.filter { $0.isAI && $0.sensitiveReason != nil }.count
    }
    private var unreviewedCount: Int {
        audit.events.filter { !audit.reviewed.contains($0.id) }.count
    }

    private func tile(_ label: String, _ value: String, tone: Color = Lumen.Palette.text, symbol: String = "") -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if !symbol.isEmpty {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(Lumen.Palette.textFaint)
                }
                MicroText(label)
            }
            MonoText(text: value, size: 15, weight: .light, color: tone)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenPanel()
    }

    private var inactiveNotice: some View {
        NoticeBar(level: .caution,
                  text: "文件审计需要已签名并获批的 Endpoint Security 扩展及完全磁盘访问。当前未采集文件事件；下方历史记录不代表正在监测。")
    }

    private var gapsNotice: some View {
        NoticeBar(level: .caution, text: audit.gaps.map { L10n.text($0) }.joined(separator: " · "))
    }

    // ---------------------------------------------------------------- 筛选

    private var filterPanel: some View {
        LumenPanel("筛选", code: "FILTER") {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), alignment: .leading, spacing: 10) {
                    filterField("程序") {
                        Picker("", selection: $scope) {
                            Text(L10n.text("全部程序")).tag("全部程序")
                            Text(L10n.text("AI 工具（推测）")).tag("AI 工具（推测）")
                        }.id(localizationState.revision)
                    }
                    filterField("应用") {
                        Picker("", selection: $application) {
                            Text(L10n.text("全部应用")).tag("全部应用")
                            ForEach(Array(Set(audit.events.map(\.executable))).sorted(), id: \.self) { path in
                                Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                            }
                        }.id(localizationState.revision)
                    }
                    filterField("操作") {
                        Picker("", selection: $operation) {
                            ForEach(["全部操作", "打开 / 可能读取", "创建", "修改", "删除", "移动"], id: \.self) {
                                Text(L10n.text($0)).tag($0)
                            }
                        }.id(localizationState.revision)
                    }
                    filterField("时间") {
                        Picker("", selection: $period) {
                            ForEach(["最近 1 小时", "最近 24 小时", "全部历史"], id: \.self) {
                                Text(L10n.text($0)).tag($0)
                            }
                        }.id(localizationState.revision)
                    }
                }

                HStack(spacing: Lumen.Metrics.s5) {
                    Toggle(L10n.text("仅敏感路径"), isOn: $sensitiveOnly)
                        .toggleStyle(.checkbox)
                        .font(Lumen.Typo.dense())
                    Toggle(L10n.text("仅待核实"), isOn: $unreviewedOnly)
                        .toggleStyle(.checkbox)
                        .font(Lumen.Typo.dense())
                    Spacer(minLength: Lumen.Metrics.s3)
                    Button(L10n.text("查看全部活动")) {
                        scope = "全部程序"
                        sensitiveOnly = false
                        application = "全部应用"
                        period = "全部历史"
                        unreviewedOnly = false
                    }
                    .lumenButton(.plain, compact: true)
                }
            }
        }
    }

    private func filterField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            MicroText(title)
            content()
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // ---------------------------------------------------------------- 表格

    private static let columns: [ColumnSpec] = [
        .fixed("时间", 78, numeric: true),
        .flex("程序", min: 110, ideal: 140),
        .fixed("核实", 68),
        .flex("操作", min: 115, ideal: 140),
        .flex("关注", min: 120, ideal: 160),
        .flex("文件路径", min: 180, ideal: 320)
    ]

    private var eventTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                    Text(L10n.text(column.title))
                        .microLabel()
                        .frame(maxWidth: column.fileFlexible ? .infinity : nil, alignment: column.alignment)
                        .frame(width: column.fileFixed, alignment: column.alignment)
                        .padding(.horizontal, 10)
                }
            }
            .frame(height: 26)
            .hairlineBottom()

            if records.isEmpty {
                EmptyState(
                    symbol: "doc.text.magnifyingglass",
                    title: (audit.active || !audit.events.isEmpty) ? "当前筛选下暂无文件访问事件" : "文件审计尚未采集",
                    detail: (audit.active || !audit.events.isEmpty)
                        ? "等待程序访问文件，或调整筛选条件。"
                        : "开始审计后，可查看哪个程序在何时访问了哪些文件。"
                )
                .frame(height: 240)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(records) { record in
                        FileEventRow(
                            record: record,
                            reviewed: audit.reviewed.contains(record.id),
                            selected: selected == record.id,
                            onTap: { selected = record.id }
                        )
                    }
                }
            }
        }
        .lumenPanel()
        .frame(maxHeight: 380)
        .clipped()
    }

    // ---------------------------------------------------------------- 详情

    private func detailPanel(_ record: FileAuditRecord) -> some View {
        LumenPanel("选中事件详情", code: "DETAIL") {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                VStack(alignment: .leading, spacing: 3) {
                    DetailPair(key: "程序", value: "\(record.application) · PID \(record.pid)")
                    DetailPair(key: "可执行文件", value: record.executable, mono: true)
                    DetailPair(key: "操作", value: L10n.text(record.operation))
                    DetailPair(key: "时间", value: record.date.formatted())
                    DetailPair(key: "文件路径", value: record.path, mono: true)
                    if let destination = record.destination {
                        DetailPair(key: "目标路径", value: destination, mono: true)
                    }
                    if let reason = record.sensitiveReason {
                        DetailPair(key: "敏感规则", value: L10n.text(reason))
                    }
                }

                if !record.processMetadata.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        MicroText("进程元数据")
                        MonoText(text: record.processMetadata.sorted { $0.key < $1.key }
                            .map { $0.key + "=" + $0.value }.joined(separator: "  ·  "),
                                 size: 10, color: Lumen.Palette.textMuted)
                            .textSelection(.enabled)
                    }
                }

                NoticeBar(level: .info, text: record.explanation, symbol: "info.circle")

                VStack(alignment: .leading, spacing: 5) {
                    MicroText("AI 关联")
                    Text(L10n.text(record.aiEvidence))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textMuted)
                    if let usage = aiUsage.likelyMatch(for: record) {
                        Text(L10n.format("可能关联的模型会话：%{0} · %{1} · %{2} tokens",
                                         arguments: [usage.tool, usage.model, usage.totalTokens.formatted()]))
                            .font(Lumen.Typo.caption())
                            .foregroundStyle(Lumen.Palette.text)
                        if let directory = usage.workingDirectory {
                            MonoText(text: directory, size: 10, color: Lumen.Palette.textFaint)
                        }
                        Text(L10n.text("关联依据是工作目录与时间接近；这不能证明该模型直接执行了此文件操作。"))
                            .font(Lumen.Typo.caption())
                            .foregroundStyle(Lumen.Palette.textFaint)
                    } else if record.isAI {
                        Text(L10n.text("未找到可关联的本机模型用量记录；AI 程序标签与会话归属均为推测。"))
                            .font(Lumen.Typo.caption())
                            .foregroundStyle(Lumen.Palette.textFaint)
                    }
                }

                Divider().overlay(Lumen.Palette.hairlineSoft)

                AdaptiveGrid(minimum: 132, spacing: 8) {
                    Button(L10n.text("定位文件")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)])
                    }.lumenButton(.secondary, compact: true)

                    Button(L10n.text("定位程序")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.executable)])
                    }.lumenButton(.secondary, compact: true)

                    Button(L10n.text("复制事件详情")) { copyDetails(record) }
                        .lumenButton(.secondary, compact: true)

                    Button(L10n.text("查看网络活动")) { _ = DashboardWindow.open(.network) }
                        .lumenButton(.secondary, compact: true)

                    Button(L10n.text("管理运行进程")) { _ = DashboardWindow.open(.processes) }
                        .lumenButton(.secondary, compact: true)

                    Button(L10n.text("标记已核实")) { audit.markReviewed(record) }
                        .lumenButton(.secondary, compact: true)
                        .disabled(audit.reviewed.contains(record.id))
                }

                Text(L10n.text("若访问不符合预期，可在进程管理中退出对应应用，并检查网络活动。退出应用不能撤销已经发生的读取；已核实只是人工标记，不表示事件安全。当前审计不会拦截文件访问。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // ---------------------------------------------------------------- 说明

    private var notesDisclosure: some View {
        DisclosureGroup(isExpanded: $showingNotes) {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s2) {
                Text(L10n.text(audit.historyStatus))
                if !audit.active {
                    Text(L10n.text("Endpoint Security 授权申请已提交。获批并完成扩展签名、安装、系统批准及完全磁盘访问后，才能开始全机采集。下方历史记录不代表当前正在监测。"))
                    Text(L10n.text(extensions.status))
                }
                Text(L10n.text("记录打开、创建、写入、关闭、修改后关闭、删除与移动事件；不能证明逐次 read/write、正文内容或数据外传。AI 标签按程序路径或签名标识推测，敏感标签按路径规则匹配，均需人工核实。AI 子进程可能无法归属。历史仅存本机路径和事件元数据，不保存文件正文；保留期、数量上限及系统事件缺口会影响完整性。"))
                Text(L10n.text("模型用量仅从本机 Codex 与 Claude Code 会话日志读取。文件事件与模型会话只按项目目录和时间窗口作启发式关联，不代表因果关系；提示词、回复正文和凭据不会被保存。"))
            }
            .font(Lumen.Typo.caption())
            .foregroundStyle(Lumen.Palette.textFaint)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, Lumen.Metrics.s2)
            .textSelection(.enabled)
        } label: {
            MicroText("采集与历史说明")
        }
        .padding(.horizontal, 2)
    }

    private var footer: some View {
        PageFooter(
            leading: paused ? "显示已暂停" : audit.status,
            tone: paused ? .caution : (audit.active ? .active : .caution),
            trailing: [
                L10n.format("显示 %{0} / %{1} 条", arguments: [String(records.count), String(audit.events.count)]),
                L10n.format("AI 敏感访问 %{0} 条", arguments: [String(aiSensitiveCount)]),
                selectedRecord == nil ? "选中事件查看详情" : "已选中 1 项"
            ]
        )
    }

    // ---------------------------------------------------------------- 操作

    private func copyDetails(_ record: FileAuditRecord) {
        let details = [
            record.date.formatted(),
            record.application + " · PID " + record.pid,
            record.executable,
            L10n.text(record.operation),
            record.path,
            record.destination ?? "",
            L10n.text(record.aiEvidence),
            record.sensitiveReason.map { L10n.text($0) } ?? "",
            L10n.text(record.explanation)
        ].filter { !$0.isEmpty }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(details, forType: .string)
    }

    private func exportRecords() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = L10n.text("安全活动.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows: [[String: Any]] = records.map { record in
            var row: [String: Any] = [
                "time": ISO8601DateFormatter().string(from: record.date),
                "pid": record.pid,
                "executable": record.executable,
                "kind": record.kind,
                "operation": record.operation,
                "path": record.path,
                "aiHeuristic": record.isAI
            ]
            row["processMetadata"] = record.processMetadata
            row["reviewed"] = audit.reviewed.contains(record.id)
            row["aiEvidence"] = record.aiEvidence
            row["explanation"] = record.explanation
            if let destination = record.destination { row["destinationPath"] = destination }
            if let reason = record.sensitiveReason { row["sensitivePathRule"] = reason }
            return row
        }
        let activityRows: [[String: Any]] = activity.events.map { event in
            [
                "time": ISO8601DateFormatter().string(from: event.date),
                "process": event.process,
                "pid": event.pid,
                "type": L10n.text(event.title),
                "detail": event.detail,
                "warningHeuristic": event.isWarning
            ]
        }
        let agentRows: [[String: Any]] = agentEvents.events.map { event in
            [
                "time": ISO8601DateFormatter().string(from: event.date),
                "provider": event.provider,
                "sessionID": event.sessionID,
                "callID": event.callID,
                "tool": event.tool,
                "workingDirectory": event.workingDirectory,
                "path": event.path,
                "command": event.command,
                "outcome": event.outcome,
                "decision": event.decision,
                "warningHeuristic": event.reason
            ]
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "events": rows,
                "applicationActivity": activityRows,
                "aiToolActivity": agentRows,
                "gaps": audit.gaps,
                "scope": scope,
                "operation": operation,
                "sensitiveOnly": sensitiveOnly,
                "limit": 10000,
                "retentionDays": 7,
                "storageStatus": audit.historyStatus,
                "application": application,
                "period": period,
                "unreviewedOnly": unreviewedOnly,
                "blocksAccess": false
            ], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            exportError = ""
        } catch {
            exportError = "导出失败：" + error.localizedDescription
        }
    }
}

private struct SecurityActivityEvent: Identifiable {
    let id = UUID()
    let date: Date
    let title: String
    let process: String
    let pid: Int32
    let detail: String
    let symbol: String
    let isWarning: Bool
}

/// Read-only, foreground monitoring for application launches and new socket connections.
/// File events remain sourced from the separately authorized Endpoint Security extension.
@MainActor
private final class SecurityActivityMonitor: ObservableObject {
    @Published private(set) var events: [SecurityActivityEvent] = []
    @Published private(set) var isMonitoring = false

    private var launchObserver: NSObjectProtocol?
    private var timer: Timer?
    private var knownConnections: Set<String> = []
    private var hasNetworkBaseline = false
    private var samplingNetwork = false

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let path = app.executableURL?.path ?? ""
            let process = app.localizedName ?? URL(fileURLWithPath: path).lastPathComponent
            let pid = app.processIdentifier
            let suspicious = Self.isRiskyPath(path)
            Task { @MainActor [weak self] in
                self?.append(SecurityActivityEvent(
                    date: Date(),
                    title: suspicious ? "从非应用目录启动" : "应用启动",
                    process: process,
                    pid: pid,
                    detail: path.isEmpty ? "未能读取可执行文件路径" : path,
                    symbol: "app.badge",
                    isWarning: suspicious
                ))
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.sampleConnections() }
        }
        sampleConnections()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        timer?.invalidate()
        timer = nil
        if let launchObserver { NSWorkspace.shared.notificationCenter.removeObserver(launchObserver) }
        launchObserver = nil
        hasNetworkBaseline = false
    }

    func clearHistory() { events.removeAll() }

    private func sampleConnections() {
        guard isMonitoring, !samplingNetwork else { return }
        samplingNetwork = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let sample = try? NetworkInspector.connections()
            DispatchQueue.main.async {
                guard let self else { return }
                self.samplingNetwork = false
                guard self.isMonitoring else { return }
                guard let connections = sample else { return }
                let current = Set(connections.map(\.id))
                if self.hasNetworkBaseline {
                    for connection in connections where !self.knownConnections.contains(connection.id) && connection.remote != "*" {
                        let suspicious = Self.isRiskyPath(Self.executablePath(pid: connection.pid))
                        self.append(SecurityActivityEvent(
                            date: Date(),
                            title: suspicious ? "可疑路径程序建立网络连接" : "新建网络连接",
                            process: connection.process,
                            pid: connection.pid,
                            detail: "\(connection.protocolName)  \(connection.local) → \(connection.remote)",
                            symbol: "network",
                            isWarning: suspicious
                        ))
                    }
                } else {
                    self.hasNetworkBaseline = true
                }
                self.knownConnections = current
            }
        }
    }

    private func append(_ event: SecurityActivityEvent) {
        events.insert(event, at: 0)
        if events.count > 500 { events.removeLast(events.count - 500) }
    }

    private static func executablePath(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return "" }
        return String(cString: buffer)
    }

    nonisolated private static func isRiskyPath(_ path: String) -> Bool {
        guard !path.isEmpty else { return false }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let riskyRoots = ["/Downloads/", "/Desktop/", "/.Trash/", "/private/tmp/", "/tmp/", "/Library/LaunchAgents/", "/Library/LaunchDaemons/"]
        return riskyRoots.contains { normalized.contains($0) }
    }
}

private extension ColumnSpec {
    var fileFlexible: Bool { if case .flexible = width { return true }; return false }
    var fileFixed: CGFloat? { if case .fixed(let w) = width { return w }; return nil }
}

// ============================================================================
// MARK: - 事件行
// ============================================================================

private struct FileEventRow: View {
    let record: FileAuditRecord
    let reviewed: Bool
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        GridRow(selected: selected, onTap: onTap) {
            HStack(spacing: 0) {
                MonoText(text: record.date.formatted(date: .omitted, time: .standard), size: 10.5, color: Lumen.Palette.textMuted)
                    .padding(.horizontal, 10)
                    .frame(width: 78, alignment: .leading)

                HStack(spacing: 7) {
                    AppGlyph(name: record.application, image: NSWorkspace.shared.icon(forFile: record.executable), size: 17)
                    Text(record.application)
                        .font(Lumen.Typo.dense())
                        .foregroundStyle(Lumen.Palette.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(record.executable)

                HStack {
                    Pill(reviewed ? "已核实" : "待核实", tone: reviewed ? .neutral : .caution)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(width: 68)

                HStack {
                    Text(L10n.text(record.operation))
                        .font(Lumen.Typo.dense())
                        .foregroundStyle(Lumen.Palette.textMuted)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 4) {
                    let labels = [record.isAI ? L10n.text("AI（推测）") : nil,
                                  record.sensitiveReason.map { L10n.text($0) }].compactMap { $0 }
                    ForEach(labels, id: \.self) { label in
                        Pill(label, tone: record.sensitiveReason == nil ? .neutral : .caution)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(record.path)
                    .font(Lumen.Typo.mono(10))
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(record.path)
            }
        }
    }
}
