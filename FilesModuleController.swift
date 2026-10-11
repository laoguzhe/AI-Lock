import AppKit
import SwiftUI

final class FilesModuleController: ModuleViewController {
    override func loadView() { view = NSHostingView(rootView: FileAuditPage()) }
    // The shared audit session continues when navigating between modules.
    func stop() {}
}

private struct FileAuditPage: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @ObservedObject private var audit = AuditExtensionClient.shared
    @ObservedObject private var extensions = SystemExtensionController.shared
    @ObservedObject private var aiUsage = AIUsageTracker.shared
    @State private var scope = "AI 工具（推测）"
    @State private var operation = "全部操作"
    @State private var sensitiveOnly = true
    @State private var application = "全部应用"
    @State private var period = "最近 24 小时"
    @State private var unreviewedOnly = false
    @State private var confirmClear = false
    @State private var selected: UUID?
    @State private var paused = false
    @State private var frozen: [FileAuditRecord] = []
    @State private var exportError = ""
    private var records: [FileAuditRecord] {
        (paused ? frozen : audit.events).filter {
            (scope != "AI 工具（推测）" || $0.isAI) && (!sensitiveOnly || $0.sensitiveReason != nil) &&
            (application == "全部应用" || $0.executable == application) &&
            (period == "全部历史" || $0.date >= Date().addingTimeInterval(period == "最近 1 小时" ? -3600 : -86400)) &&
            (!unreviewedOnly || !audit.reviewed.contains($0.id)) &&
            (operation == "全部操作" || (operation == "打开 / 可能读取" && $0.kind == "open") ||
             (operation == "修改" && ($0.operation == "修改后关闭" || $0.kind == "write")) || (operation == "创建" && $0.kind == "create") || (operation == "删除" && $0.kind == "unlink") ||
             (operation == "移动" && $0.kind == "rename"))
        }
    }
    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle().fill(audit.active ? Color.green : Color.orange).frame(width: 8, height: 8)
                Text(L10n.text(audit.status)).lineLimit(1).help(L10n.text(audit.status))
                Spacer(minLength: 12)
                Button(L10n.text(audit.active ? "停止采集" : "开始全机审计")) {
                    if audit.active { audit.stop() } else { audit.start(root: URL(fileURLWithPath: "/")) }
                }.disabled(audit.busy)
                Menu(L10n.text("更多操作")) {
                    Button(L10n.text(paused ? "继续显示" : "暂停显示")) {
                        if !paused { frozen = audit.events }; paused.toggle()
                    }
                    Button(L10n.text("导出")) { exportRecords() }.disabled(records.isEmpty)
                    Button(L10n.text("清空历史…")) { confirmClear = true }.disabled(audit.events.isEmpty)
                    Divider()
                    Button(L10n.text("查询审计扩展")) { extensions.queryAudit() }.disabled(extensions.busy)
                    Button(L10n.text("安装 / 更新审计扩展")) { extensions.activateAudit() }.disabled(extensions.busy)
                    Button(L10n.text("打开完全磁盘访问设置")) { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!) }
                }.fixedSize()
            }
            AIUsageCard(tracker: aiUsage, english: L10n.isEnglish)
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4), alignment: .leading, spacing: 8) {
                    filterField("程序") {
                        Picker("", selection: $scope) { Text(L10n.text("全部程序")).tag("全部程序"); Text(L10n.text("AI 工具（推测）")).tag("AI 工具（推测）") }
                    }
                    filterField("应用") {
                        Picker("", selection: $application) {
                            Text(L10n.text("全部应用")).tag("全部应用")
                            ForEach(Array(Set(audit.events.map(\.executable))).sorted(), id: \.self) { path in
                                Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                            }
                        }
                    }
                    filterField("操作") {
                        Picker("", selection: $operation) { ForEach(["全部操作", "打开 / 可能读取", "创建", "修改", "删除", "移动"], id: \.self) { Text(L10n.text($0)) } }
                    }
                    filterField("时间") {
                        Picker("", selection: $period) { ForEach(["最近 1 小时", "最近 24 小时", "全部历史"], id: \.self) { Text(L10n.text($0)) } }
                    }
                }
                HStack(spacing: 20) {
                    Toggle(L10n.text("仅敏感路径"), isOn: $sensitiveOnly).toggleStyle(.checkbox)
                    Toggle(L10n.text("仅待核实"), isOn: $unreviewedOnly).toggleStyle(.checkbox)
                    Spacer()
                    Button(L10n.text("查看全部活动")) { scope = "全部程序"; sensitiveOnly = false; application = "全部应用"; period = "全部历史"; unreviewedOnly = false }
                        .buttonStyle(.link)
                }
            }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            if !audit.active {
                HStack(spacing: 8) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(L10n.text("授权申请已提交，完成扩展授权后可开始采集。")).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            Table(records, selection: $selected) {
                TableColumn(L10n.text("时间")) { Text($0.date.formatted(date: .omitted, time: .standard)) }.width(80)
                TableColumn(L10n.text("程序")) { Text($0.application).help($0.executable) }.width(min: 100, ideal: 130)
                TableColumn(L10n.text("核实")) { Text(L10n.text(audit.reviewed.contains($0.id) ? "已核实" : "待核实")) }.width(70)
                TableColumn(L10n.text("操作")) { Text(L10n.text($0.operation)) }.width(min: 115, ideal: 145)
                TableColumn(L10n.text("关注")) { record in
                    Text(L10n.text([record.isAI ? L10n.text("AI（推测）") : nil, record.sensitiveReason.map { L10n.text($0) }].compactMap { $0 }.joined(separator: " · ")))
                        .foregroundStyle(record.sensitiveReason == nil ? Color.secondary : Color.orange)
                }.width(min: 110, ideal: 150)
                TableColumn(L10n.text("文件路径")) { Text($0.path).truncationMode(.middle).help($0.path) }.width(min: 160, ideal: 300)
            }
            .overlay {
                if records.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass").font(.system(size: 28)).foregroundStyle(.secondary)
                        Text(L10n.text((audit.active || !audit.events.isEmpty) ? L10n.text("当前筛选下暂无文件访问事件") : L10n.text("文件审计尚未采集"))).font(.headline)
                        Text(L10n.text((audit.active || !audit.events.isEmpty) ? L10n.text("等待程序访问文件，或调整筛选条件。") : L10n.text("开始审计后，可查看哪个程序在何时访问了哪些文件。"))).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .textBackgroundColor)).padding(.top, 28).allowsHitTesting(false)
                }
            }
            if let record = records.first(where: { $0.id == selected }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(L10n.text("哪个 AI 动了我的敏感信息？")).fontWeight(.semibold)
                        Text(record.application + " · PID " + record.pid + " · " + L10n.text(record.aiEvidence))
                        Text(L10n.text("程序：") + record.executable)
                        if !record.processMetadata.isEmpty {
                            Text(L10n.text("进程元数据：") + record.processMetadata.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: " · "))
                        }
                        Text(L10n.text("发生了什么？")).fontWeight(.semibold)
                        Text(record.date.formatted() + " · " + L10n.text(record.operation))
                        Text(L10n.text("文件：") + record.path)
                        if let destination = record.destination { Text(L10n.text("目标：") + destination) }
                        if let usage = aiUsage.likelyMatch(for: record) {
                            Text(L10n.text("可能关联的模型会话：\(usage.tool) · \(usage.model) · \(usage.totalTokens.formatted()) tokens"))
                            if let directory = usage.workingDirectory { Text(L10n.text("会话工作目录：") + directory) }
                            Text(L10n.text("关联依据是工作目录与时间接近；这不能证明该模型直接执行了此文件操作。"))
                                .foregroundStyle(.secondary)
                        } else if record.isAI {
                            Text(L10n.text("未找到可关联的本机模型用量记录；AI 程序标签与会话归属均为推测。"))
                                .foregroundStyle(.secondary)
                        }
                        if let reason = record.sensitiveReason { Text(L10n.text("敏感路径规则：") + L10n.text(reason)).foregroundStyle(.orange) }
                        Text(L10n.text(record.explanation)).foregroundStyle(.secondary)
                        Text(L10n.text("我现在能怎么处理？")).fontWeight(.semibold)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 8)], alignment: .leading) {
                            Button(L10n.text("定位文件")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.path)]) }
                            Button(L10n.text("定位程序")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.executable)]) }
                            Button(L10n.text("复制事件详情")) { copyDetails(record) }
                            Button(L10n.text("查看网络活动")) { _ = DashboardWindow.open(.network) }
                            Button(L10n.text("管理运行进程")) { _ = DashboardWindow.open(.processes) }
                            Button(L10n.text("标记已核实")) { audit.markReviewed(record) }.disabled(audit.reviewed.contains(record.id))
                        }
                        Text(L10n.text("若访问不符合预期，可在进程管理中退出对应应用，并检查网络活动。退出应用不能撤销已经发生的读取；已核实只是人工标记，不表示事件安全。当前审计不会拦截文件访问。"))
                            .foregroundStyle(.secondary)
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 240)
            }
            HStack(spacing: 16) {
                Text(L10n.format("显示 %{0} / %{1} 条", arguments: [String(records.count), String(audit.events.count)]))
                Text(L10n.format("AI 敏感访问 %{0} 条", arguments: [String(audit.events.filter { $0.isAI && $0.sensitiveReason != nil }.count)]))
                if paused { Label(L10n.text("显示已暂停"), systemImage: "pause.circle") }
                Spacer()
                Text(L10n.text("选中事件查看详情")).foregroundStyle(.tertiary)
            }.foregroundStyle(.secondary)
            if !audit.gaps.isEmpty { Text(audit.gaps.map { L10n.text($0) }.joined(separator: " · ")).foregroundStyle(.orange).lineLimit(2).help(audit.gaps.map { L10n.text($0) }.joined(separator: " · ")) }
            if audit.historyStatus.contains("失败") || audit.historyStatus.contains("未加载") { Text(L10n.text(audit.historyStatus)).foregroundStyle(.orange) }
            if !exportError.isEmpty { Text(L10n.text(exportError)).foregroundStyle(.red) }
            DisclosureGroup(L10n.text("采集与历史说明")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.text(audit.historyStatus))
                    if !audit.active {
                        Text(L10n.text("Endpoint Security 授权申请已提交。获批并完成扩展签名、安装、系统批准及完全磁盘访问后，才能开始全机采集。下方历史记录不代表当前正在监测。"))
                        Text(L10n.text(extensions.status))
                    }
                    Text(L10n.text("记录打开、创建、写入、关闭、修改后关闭、删除与移动事件；不能证明逐次 read/write、正文内容或数据外传。AI 标签按程序路径或签名标识推测，敏感标签按路径规则匹配，均需人工核实。AI 子进程可能无法归属。历史仅存本机路径和事件元数据，不保存文件正文；保留期、数量上限及系统事件缺口会影响完整性。"))
                    Text(L10n.text("模型用量仅从本机 Codex 与 Claude Code 会话日志读取。文件事件与模型会话只按项目目录和时间窗口作启发式关联，不代表因果关系；提示词、回复正文和凭据不会被保存。"))
                }.foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 6)
            }

        }.font(.system(size: 13)).padding(20).frame(minWidth: 760, minHeight: 380)
        .alert(L10n.text("清空本地文件活动历史？"), isPresented: $confirmClear) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("清空历史"), role: .destructive) { audit.clearHistory(); frozen = []; selected = nil }
        } message: { Text(L10n.text("删除本地事件和核实标记。采集会继续，已导出的文件不会删除。")) }
    }
    private func filterField<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text(title)).foregroundStyle(.secondary)
            content().labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func copyDetails(_ record: FileAuditRecord) {
        let details = [record.date.formatted(), record.application + " · PID " + record.pid, record.executable, L10n.text(record.operation), record.path, record.destination ?? "", L10n.text(record.aiEvidence), record.sensitiveReason.map { L10n.text($0) } ?? "", L10n.text(record.explanation)].filter { !$0.isEmpty }.joined(separator: "\n")
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(details, forType: .string)
    }
    private func exportRecords() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = L10n.text("文件活动.json")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rows: [[String: Any]] = records.map { record in
            var row: [String: Any] = ["time": ISO8601DateFormatter().string(from: record.date), "pid": record.pid, "executable": record.executable, "kind": record.kind, "operation": record.operation, "path": record.path, "aiHeuristic": record.isAI]
            row["processMetadata"] = record.processMetadata
            row["reviewed"] = audit.reviewed.contains(record.id)
            row["aiEvidence"] = record.aiEvidence
            row["explanation"] = record.explanation
            if let destination = record.destination { row["destinationPath"] = destination }
            if let reason = record.sensitiveReason { row["sensitivePathRule"] = reason }
            return row
        }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["events": rows, "gaps": audit.gaps, "scope": scope, "operation": operation, "sensitiveOnly": sensitiveOnly, "limit": 10000, "retentionDays": 7, "storageStatus": audit.historyStatus, "application": application, "period": period, "unreviewedOnly": unreviewedOnly, "blocksAccess": false], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic); exportError = ""
        } catch { exportError = "导出失败：" + error.localizedDescription }
    }
}
