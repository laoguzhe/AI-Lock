import AppKit
import ServiceManagement
import SwiftUI

// ============================================================================
//  模块宿主
//  把 Lumen 界面接进现有窗口体系：保留「每个模块一个窗口、切换时挂起采样」
//  的既有生命周期，只替换窗口内部的内容层。
// ============================================================================

/// 采样挂起/恢复广播。
/// 页面窗口只是被 orderOut 隐藏而不是销毁，SwiftUI 的 onDisappear 不会触发，
/// 因此需要显式通知各页面模型停止后台采样。
extension Notification.Name {
    static let lumenModuleDidSuspend = Notification.Name("lumen.module.suspend")
    static let lumenModuleDidResume = Notification.Name("lumen.module.resume")
}

/// 页面模型订阅采样开关的工具。
struct ModuleActivityObserver: ViewModifier {
    let module: DashboardWindow.Module
    let onResume: () -> Void
    let onSuspend: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .lumenModuleDidSuspend)) { note in
                guard (note.object as? String) == module.rawValue else { return }
                onSuspend()
            }
            .onReceive(NotificationCenter.default.publisher(for: .lumenModuleDidResume)) { note in
                guard (note.object as? String) == module.rawValue else { return }
                onResume()
            }
    }
}

extension View {
    func moduleActivity(module: DashboardWindow.Module,
                        onResume: @escaping () -> Void,
                        onSuspend: @escaping () -> Void) -> some View {
        modifier(ModuleActivityObserver(module: module, onResume: onResume, onSuspend: onSuspend))
    }
}

// ============================================================================
// MARK: - 模块内容路由
// ============================================================================

/// 按模块返回对应的 Lumen 页面。
struct LumenModuleContent: View {
    @ObservedObject private var language = LumenLanguageState.shared
    let module: DashboardWindow.Module
    let clipboardHistory: ClipboardHistory
    /// 侧栏切换时回调，由 DashboardWindow 决定开窗还是复用。
    let onSelect: (DashboardWindow.Module) -> Void

    init(module: DashboardWindow.Module,
         clipboardHistory: ClipboardHistory = .shared,
         onSelect: @escaping (DashboardWindow.Module) -> Void) {
        self.module = module
        self.clipboardHistory = clipboardHistory
        self.onSelect = onSelect
    }

    var body: some View {
        let _ = language.revision
        LumenShell(selection: Binding(get: { module }, set: { onSelect($0) })) { current in
            page(for: current)
        }
    }

    @ViewBuilder
    private func page(for module: DashboardWindow.Module) -> some View {
        switch module {
        case .processes:
            LumenProcessesView()
        case .network:
            LumenNetworkView()
        case .files:
            LumenFileActivityView()
        case .clipboard:
            LumenClipboardView(history: clipboardHistory)
        case .cacheCleaner:
            LegacyMacHealthPage()
        case .uninstaller:
            LumenUninstallerView()
        case .logs:
            LumenLogsView()
        case .screenRecorder:
            LumenScreenRecorderView()
        case .displayBrightness:
            LumenDisplayBrightnessView()
        case .dockLock:
            LumenDockLockView()
        case .menuBarOrganizer:
            LumenMenuBarOrganizerView()
        case .preferences:
            LumenPreferencesView()
        case .launchItems:
            LumenLaunchItemsView()
        case .settings:
            // 「监控预警」模块：独立的阈值与提醒页。
            ModulePage(module: .settings,
                       subtitle: "调整资源预警阈值与提醒行为。",
                       content: { LumenAlertsThresholdsView() })
        case .search, .launcher:
            LumenLauncherPage()
        case .networkDiagnostics:
            // 网络诊断保留自有控制台界面（诊断仪表与区域延迟地图），
            // 由 NetworkDiagnosticsHost 构建并向外层回报采样模型。
            NetworkDiagnosticsHost()
        }
    }
}

/// 承载网络诊断控制台，并把模型交回给 DashboardWindow 管理采样生命周期。
struct NetworkDiagnosticsHost: View {
    @StateObject private var model = NetworkDiagnosticsModel()

    var body: some View {
        NetworkDiagnosticsView(model: model)
            .onAppear { DashboardWindow.registerDiagnosticsModel(model) }
            .onDisappear { model.cancel() }
            .moduleActivity(module: .networkDiagnostics,
                            onResume: { /* diagnostic runs are user-triggered */ },
                            onSuspend: { model.cancel() })
    }
}

// ============================================================================
// MARK: - 窗口尺寸
// ============================================================================

enum LumenWindowMetrics {
    static func size(for module: DashboardWindow.Module) -> NSSize {
        NSSize(width: 1120, height: 740)
    }

    static func minimumSize(for module: DashboardWindow.Module) -> NSSize {
        NSSize(width: 960, height: 620)
    }
}

// ============================================================================
// MARK: - 启动项检查（独立页面）
// ============================================================================

@MainActor
final class LaunchItemsPageModel: ObservableObject {
    @Published var items: [StartupItem] = []
    @Published var status = "正在扫描启动项和后台常驻配置…"
    @Published var busy = false
    @Published var search = ""
    @Published var onlyProblems = false

    private var generation = 0

    var problems: [StartupItem] {
        items.filter { item in
            ["无法解析", "不存在", "缺少", "未确认", "未读取"].contains { item.startupStatus.contains($0) }
        }
    }

    var visible: [StartupItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = onlyProblems ? problems : items
        guard !query.isEmpty else { return result }
        result = result.filter {
            $0.label.localizedCaseInsensitiveContains(query)
                || $0.program.localizedCaseInsensitiveContains(query)
                || $0.kind.localizedCaseInsensitiveContains(query)
        }
        return result
    }

    func scan() {
        generation += 1
        let request = generation
        busy = true
        status = "正在扫描启动项和后台常驻配置…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = StartupItemInspector.scan()
            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                self.items = result
                self.busy = false
                self.status = L10n.format("共 %{0} 项配置，其中 %{1} 项需要留意",
                                          arguments: [String(result.count), String(self.problems.count)])
                ModuleBadgeCenter.shared.report(.launchItems, self.problems.isEmpty ? nil : self.problems.count)
            }
        }
    }

    /// 移走配置前先备份；移走不等于停止正在运行的服务。
    func repair(_ item: StartupItem) {
        let alert = NSAlert()
        alert.messageText = L10n.text("备份并移走这项启动配置？")
        alert.informativeText = L10n.text("配置会被复制到 AILock 备份目录后从原位置移走。移走配置不等于立即停止正在运行的服务。")
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("备份并移走"))
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        busy = true
        status = "正在备份并移走配置…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let outcome = Result { try StartupItemRepair.quarantine(item) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch outcome {
                case .success(let backup):
                    let stillThere = FileManager.default.fileExists(atPath: item.url.path)
                    self.status = stillThere
                        ? L10n.text("配置仍在原位置，可能需要管理员权限。")
                        : L10n.format("已备份到 %{0}", arguments: [backup.path])
                case .failure(let error):
                    self.status = L10n.format("移走失败：%{0}", arguments: [String(error.localizedDescription)])
                }
                self.scan()
            }
        }
    }

    var cleanableProblems: [StartupItem] { problems.filter { $0.repairData != nil } }

    func cleanAllProblems() {
        guard !busy else { return }
        let candidates = cleanableProblems
        guard !candidates.isEmpty else { return }
        busy = true
        status = "正在备份并清理异常启动项…"
        Task {
            let summary = await Task.detached(priority: .utility) {
                var cleaned = 0
                var failures: [String] = []
                for item in candidates {
                    do { _ = try StartupItemRepair.quarantine(item); cleaned += 1 }
                    catch { failures.append(item.label + "：" + error.localizedDescription) }
                }
                let refreshed = StartupItemInspector.scan()
                return (cleaned, failures, refreshed)
            }.value
            items = summary.2
            busy = false
            status = "已备份并清理 \(summary.0) 项异常启动配置。" + (summary.1.isEmpty ? "" : "失败 \(summary.1.count) 项：" + summary.1.joined(separator: "；"))
            ModuleBadgeCenter.shared.report(.launchItems, problems.isEmpty ? nil : problems.count)
        }
    }

    func moveToTrash(_ item: StartupItem) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L10n.format("删除启动配置 %{0}？", arguments: [item.label])
        alert.informativeText = L10n.text("配置将被移入废纸篓，可从废纸篓恢复。删除配置不等于立即停止正在运行的服务。")
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("移入废纸篓"))
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        // recycle 是异步的：用 completionHandler 形式，回调里再决定是否交给 Finder 兜底。
        // 管理员权限目录需要 Finder 触发系统授权弹窗。
        NSWorkspace.shared.recycle([item.url]) { [weak self] _, recycleError in
            let outcome: Error?
            if let recycleError {
                outcome = DashboardWindow.deleteStartupItemWithFinder(item.url) ?? recycleError
            } else {
                outcome = nil
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.status = outcome?.localizedDescription ?? "已移入废纸篓。"
                self.scan()
            }
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

struct LumenLaunchItemsView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @StateObject private var model = LaunchItemsPageModel()
    @State private var selectedItemID: String?

    private static let columns: [ColumnSpec] = [
        .flex("项目", min: 150, ideal: 200),
        .fixed("来源", 150),
        .fixed("启动状态", 280),
        .flex("程序路径", min: 200, ideal: 420)
    ]

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .launchItems,
            subtitle: model.status,
            trailing: {
                Button(L10n.text("一键清理异常启动项")) { model.cleanAllProblems() }
                    .lumenButton(.primary, icon: "trash")
                    .disabled(model.busy || model.cleanableProblems.isEmpty)
                Button(L10n.text("系统登录项设置")) { model.openLoginItemsSettings() }
                    .lumenButton(.secondary, icon: "gearshape")
                Button(L10n.text("重新扫描")) { model.scan() }
                    .lumenButton(.secondary, icon: "arrow.clockwise")
                    .disabled(model.busy)
            },
            footer: {
                PageFooter(
                    leading: model.status,
                    tone: model.problems.isEmpty ? .active : .caution,
                    trailing: ["\(model.items.count) 项配置",
                               model.problems.isEmpty ? "未发现异常" : "\(model.problems.count) 项需留意"]
                )
            },
            content: {
                VStack(spacing: 0) {
                    ModuleToolbar {
                        SearchBox(placeholder: "搜索名称、来源或路径", text: $model.search, width: 230)
                        Toggle(L10n.text("仅看异常项"), isOn: $model.onlyProblems)
                            .toggleStyle(.checkbox)
                            .font(Lumen.Typo.dense())
                        Spacer(minLength: Lumen.Metrics.s2)
                        if model.problems.isEmpty && !model.items.isEmpty {
                            Pill("未发现异常", tone: .active, symbol: "checkmark")
                        }
                    }

                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVStack(spacing: 0) {
                            HStack(spacing: 0) {
                                ForEach(Array(Self.columns.enumerated()), id: \.offset) { _, column in
                                    Text(L10n.text(column.title))
                                        .microLabel()
                                        .padding(.horizontal, 10)
                                        .frame(maxWidth: column.launchFlexible ? .infinity : nil, alignment: column.alignment)
                                        .frame(width: column.launchFixed, alignment: column.alignment)
                                }
                            }
                            .frame(height: 26)
                            .hairlineBottom()

                            ForEach(model.visible) { item in
                                LaunchItemRow(item: item, isProblem: model.problems.contains { $0.id == item.id },
                                              isSelected: selectedItemID == item.id,
                                              columns: Self.columns,
                                              onSelect: { selectedItemID = item.id },
                                              onRepair: { model.repair(item) },
                                              onTrash: { model.moveToTrash(item) })
                            }

                            if model.visible.isEmpty {
                                EmptyState(symbol: "bolt.badge.clock",
                                           title: model.busy ? "正在扫描…" : "没有匹配的启动项",
                                           detail: model.busy ? nil : "调整搜索条件，或取消「仅看异常项」。")
                                    .frame(height: 240)
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .background(Lumen.Palette.canvas)

                    NoticeBar(level: .info,
                              text: "一键清理会先备份，再移走目标缺失或无法解析的用户启动配置；其他异常需手动检查。移走配置不会立即停止服务。")
                        .padding(.horizontal, Lumen.Metrics.pageInset)
                        .padding(.bottom, Lumen.Metrics.s3)
                }
            }
        )
        .onAppear { if model.items.isEmpty { model.scan() } }
    }
}

private extension ColumnSpec {
    var launchFlexible: Bool { if case .flexible = width { return true }; return false }
    var launchFixed: CGFloat? { if case .fixed(let w) = width { return w }; return nil }
}

private struct LaunchItemRow: View {
    let item: StartupItem
    let isProblem: Bool
    let isSelected: Bool
    let columns: [ColumnSpec]
    let onSelect: () -> Void
    let onRepair: () -> Void
    let onTrash: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 8) {
                AppGlyph(name: item.label, image: ApplicationArtwork.startup(program: item.program, label: item.label), size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.label)
                        .font(Lumen.Typo.dense())
                        .foregroundStyle(Lumen.Palette.text)
                        .lineLimit(1)
                    if isProblem {
                        Text(L10n.text(item.repairAdvice))
                            .font(.system(size: 9.5))
                            .foregroundStyle(Lumen.Palette.cautionInk)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, alignment: .leading)

            cell(item.kind, width: columns[1].launchFixed ?? 150, mono: true, tone: Lumen.Palette.textMuted)

            Text(item.startupStatus)
                .font(.system(size: 10 * Lumen.scale, weight: .medium))
                .foregroundStyle(isProblem ? Lumen.Palette.cautionInk : Lumen.Palette.textMuted)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 19)
                .background(isProblem ? Lumen.Palette.cautionWash : Lumen.Palette.fill,
                            in: RoundedRectangle(cornerRadius: Lumen.Metrics.rChip, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rChip, style: .continuous)
                    .strokeBorder(isProblem ? Lumen.Palette.caution.opacity(0.28) : Lumen.Palette.hairlineHard, lineWidth: 1))
                .padding(.horizontal, 10)
                .frame(width: columns[2].launchFixed ?? 280)

            Text(item.program.isEmpty ? item.url.path : item.program)
                .font(Lumen.Typo.mono(10))
                .foregroundStyle(Lumen.Palette.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .background(isSelected ? Lumen.Palette.rowSelected : Color.clear,
                    in: RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button(L10n.text("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            Divider()
            Button(L10n.text("备份并移走配置…")) { onRepair() }
            Button(L10n.text("移入废纸篓…"), role: .destructive) { onTrash() }
        }
    }

    private func cell(_ text: String, width: CGFloat, mono: Bool, tone: Color) -> some View {
        HStack {
            if mono {
                MonoText(text: text, size: 10.5, color: tone).lineLimit(1)
            } else {
                Text(text).font(Lumen.Typo.dense()).foregroundStyle(tone).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(width: width)
    }
}

// ============================================================================
// MARK: - 快捷搜索页（窗口形态）
// ============================================================================

@MainActor
final class LauncherPageModel: ObservableObject {
    @Published var query = ""
    @Published var results: [SearchResult] = []
    @Published var needsDiskAccess = false

    private let engine = QuickSearch.shared

    func update(_ value: String) {
        query = value
        engine.search(value) { [weak self] results in
            self?.results = results
            self?.needsDiskAccess = QuickSearch.shared.requiresFullDiskAccess
        }
    }

    func open(_ result: SearchResult) {
        engine.open(result)
    }

    func openDiskAccessSettings() {
        SearchDiskAccess.openSettings()
    }
}

struct LumenLauncherPage: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @StateObject private var model = LauncherPageModel()

    var body: some View {
        let _ = localizationState.revision
        ModulePage(
            module: .search,
            subtitle: "搜索本机应用、文件与文件夹。输入路径可直接定位。",
            trailing: {
                Button(L10n.text("磁盘访问设置")) { model.openDiskAccessSettings() }
                    .lumenButton(.secondary, icon: "externaldrive")
            },
            content: {
                VStack(alignment: .leading, spacing: 0) {
                    ModuleToolbar {
                        SearchBox(placeholder: "搜索应用、文件或文件夹", text: Binding(
                            get: { model.query },
                            set: { model.update($0) }
                        ), width: 420)
                        Spacer(minLength: 0)
                    }

                    if model.needsDiskAccess {
                        NoticeBar(level: .caution,
                                  text: "文件访问被系统拦截，搜索范围受限。授权完全磁盘访问后可以搜索更多位置。")
                            .padding(.horizontal, Lumen.Metrics.pageInset)
                            .padding(.bottom, Lumen.Metrics.s3)
                    }

                    if model.results.isEmpty {
                        EmptyState(symbol: model.query.isEmpty ? "magnifyingglass" : "questionmark.folder",
                                   title: model.query.isEmpty ? "输入关键词开始搜索" : "没有匹配结果",
                                   detail: model.query.isEmpty
                                       ? "支持应用名称、文件名，以及以 / 或 ~ 开头的完整路径。"
                                       : "换个关键词，或尝试输入完整路径。")
                            .frame(maxHeight: .infinity)
                    } else {
                        ScrollView(.vertical, showsIndicators: true) {
                            LazyVStack(spacing: 0) {
                                ForEach(model.results) { result in
                                    ResultRow(result: result) { model.open(result) }
                                }
                            }
                        }
                        .scrollContentBackground(.hidden)
                    }
                }
            }
        )
    }
}

private struct ResultRow: View {
    let result: SearchResult
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: Lumen.Metrics.s3) {
            Image(nsImage: result.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.text(result.title))
                    .font(Lumen.Typo.dense())
                    .foregroundStyle(Lumen.Palette.text)
                    .lineLimit(1)
                MonoText(text: result.path, size: 9.5, color: Lumen.Palette.textGhost)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Lumen.Metrics.s2)
            Pill(result.typeLabel, tone: .neutral)
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .frame(height: 42)
        .background(hovering ? Lumen.Palette.rowHover : .clear)
        .hairlineBottom()
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .contextMenu {
            Button(L10n.text("打开")) { onOpen() }
            Button(L10n.text("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: result.path)])
            }
        }
    }
}
