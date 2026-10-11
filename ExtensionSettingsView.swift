import SwiftUI
import AppKit

struct ExtensionSettingsView: View {
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    @ObservedObject private var extensions = SystemExtensionController.shared
    @ObservedObject private var filter = ContentFilterConfiguration.shared
    @ObservedObject private var health = ContentFilterConfiguration.shared.health
    @ObservedObject private var audit = AuditExtensionClient.shared
    @State private var rules = ""
    @State private var confirmEnable = false
    @State private var applicationHost = ""
    @State private var applicationError = ""
    private var busy: Bool { extensions.busy || filter.busy }
    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.text("连接过滤")).font(.headline)
            Text(L10n.text("按精确远端主机或 IP 阻断连接。端点可能是 IP，域名规则不保证覆盖 DNS/CDN 或代理。没有主机和应用规则时允许所有连接。")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text(extensions.status)).font(.caption)
            HStack {
                Button(L10n.text("查询扩展状态")) { extensions.queryFilter() }
                Button(L10n.text("安装 / 更新扩展")) { extensions.activateFilter() }
                Button(L10n.text("移除扩展")) { extensions.deactivateFilter() }
            }.disabled(busy)
            TextEditor(text: $rules).font(.system(.body, design: .monospaced)).frame(height: 90).border(Color.secondary.opacity(0.25))
            Text(L10n.text("每行一个精确主机或 IP，最多 256 条；不支持通配符或端口。")).font(.caption).foregroundStyle(.secondary)
            Text(L10n.text("按应用阻断")).font(.subheadline)
            HStack {
                TextField(L10n.text("可选：仅阻断此应用访问某个精确主机 / IP"), text: $applicationHost)
                Button(L10n.text("选择应用并添加")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true; panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            let identity = try SignedApplicationResolver.selectedApplication(url)
                            let host = applicationHost.trimmingCharacters(in: .whitespacesAndNewlines)
                            var next = filter.draft
                            next.applications.append(ApplicationBlockRule(application: identity, host: host.isEmpty ? nil : host))
                            filter.draft = try next.validated(); applicationError = ""
                        } catch { applicationError = error.localizedDescription }
                    }
                }
            }.disabled(busy)
            Text(L10n.text("留空表示阻断该应用所有新连接；按签名标识与开发者团队匹配，最多 128 条。未签名应用暂不支持。")).font(.caption).foregroundStyle(.secondary)
            if !applicationError.isEmpty { Text(L10n.text(applicationError)).font(.caption).foregroundStyle(.red) }
            if !filter.draft.applications.isEmpty {
                ScrollView {
                    ForEach(filter.draft.applications) { rule in
                        HStack {
                            Text(L10n.text(rule.application.identifier + " · " + rule.application.teamID + " → " + (rule.host ?? L10n.text("全部主机")))).font(.caption).textSelection(.enabled)
                            Spacer()
                            Button(L10n.text("删除")) { filter.draft.applications.removeAll { $0.id == rule.id } }.disabled(busy)
                        }
                    }
                }.frame(maxHeight: 110)
            }
            Toggle(L10n.text("过滤器故障时优先恢复联网"), isOn: $filter.draft.automaticallyRecover).disabled(busy)
            Text(L10n.text("默认关闭。开启后，连续 3 次心跳异常会停用本应用过滤配置；应用退出或失联 30 秒后，仍运行的过滤器会放行新连接。断网和休眠不触发应用端自动停用。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("查询过滤配置")) { filter.refresh() }
                Button(L10n.text("保存并启用")) { confirmEnable = true }
                Button(L10n.text("停用过滤")) { filter.apply(hosts: [], enabled: false) }
            }.disabled(busy)
            Text(L10n.text(filter.status)).font(.caption)
            Text(L10n.text(health.status)).font(.caption).foregroundStyle(health.healthy ? .green : .secondary)
            Divider()
            Text(L10n.text("文件审计扩展")).font(.headline)
            Text(L10n.text("NOTIFY 元数据事件，不读取正文；最多显示 500 条，交付窗口可能遗漏，不是持久完整审计日志。")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(L10n.text("查询审计扩展")) { extensions.queryAudit() }
                Button(L10n.text("安装 / 更新审计")) { extensions.activateAudit() }
                Button(L10n.text("移除审计扩展")) { extensions.deactivateAudit() }
            }.disabled(busy || audit.busy)
            HStack {
                Button(L10n.text("选择目录并开始审计")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let root = panel.url { audit.start(root: root) }
                }.disabled(busy || audit.busy)
                Button(L10n.text("停止审计")) { audit.stop() }
            }
            Text(L10n.text(audit.status)).font(.caption)
            if !audit.lines.isEmpty { ScrollView { Text(audit.lines.joined(separator: "\n")).font(.system(.caption, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(height: 100) }

        }.onChange(of: filter.draft.blockedHosts) { _, hosts in rules = hosts.joined(separator: "\n") }
        .onAppear { rules = filter.draft.blockedHosts.joined(separator: "\n") }
        .alert(L10n.text("启用连接过滤？"), isPresented: $confirmEnable) {
            Button(L10n.text("取消"), role: .cancel) {}
            Button(L10n.text("启用")) { filter.apply(hosts: rules.split(whereSeparator: \.isNewline).map(String.init), enabled: true) }
        } message: { Text(L10n.text("符合列表的连接将被阻断。系统可能要求批准；保存失败时会尝试恢复并复核原配置。")) }
    }
}
