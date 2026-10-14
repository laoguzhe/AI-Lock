import AppKit
import SwiftUI

// ============================================================================
//  应用卸载 / 系统扩展清理
//  增量扫描、身份复核、关联项勾选、废纸篓执行的语义与顺序保持不变。
// ============================================================================

@MainActor
final class UninstallerPageModel: ObservableObject {
    @Published var apps: [InstalledApplication] = []
    @Published var extensions: [UninstallableExtension] = []
    @Published var selected: Set<String> = []
    @Published var selectedExtensions: Set<String> = []
    @Published var busy = false
    @Published var scanning = false
    @Published var status = "正在读取应用列表…"
    @Published var mode: Mode = .applications
    @Published var search = ""
    @Published var category: ExtensionUninstallCategory = .installers
    @Published var reviewTarget: ReviewTarget?

    enum Mode: Hashable { case applications, extensions }

    /// 待确认的卸载目标：应用及其关联项，或扩展项。
    struct ReviewTarget: Identifiable {
        let id = UUID()
        let apps: [InstalledApplication]
        let related: [[UninstallItem]]
        let extensions: [UninstallableExtension]

        var isExtension: Bool { !extensions.isEmpty }
    }

    // ---------------------------------------------------------------- 扫描

    func refresh() {
        guard !busy, !scanning else { return }
        scanning = true
        status = "正在扫描应用与扩展…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let extensions = ExtensionUninstaller.scan()
            var collected: [InstalledApplication] = []
            var seen = Set<String>()
            ApplicationUninstaller.scanIncrementally { batch in
                // 就地合并，避免列表在增量扫描时反复重排。
                for app in batch where seen.insert(app.id).inserted {
                    collected.append(app)
                }
                let snapshot = collected.sorted {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.apps = snapshot
                    self.status = L10n.format("已发现 %{0} 个应用", arguments: [String(snapshot.count)])
                }
            }
            let final = collected.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.apps = final
                self.extensions = extensions
                self.scanning = false
                self.status = L10n.format("已发现 %{0} 个应用、%{1} 个可清理扩展",
                                          arguments: [String(final.count), String(extensions.count)])
                let known = Set(final.map(\.id))
                self.selected.formIntersection(known)
                let knownExtensions = Set(extensions.map(\.id))
                self.selectedExtensions.formIntersection(knownExtensions)
                ModuleBadgeCenter.shared.report(.uninstaller, extensions.count)
            }
        }
    }

    // ---------------------------------------------------------------- 过滤

    var visibleApps: [InstalledApplication] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        return apps.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
    }

    var visibleExtensions: [UninstallableExtension] {
        extensions.filter { $0.category == category }
    }

    func categoryCount(_ category: ExtensionUninstallCategory) -> Int {
        extensions.filter { $0.category == category }.count
    }

    func categorySize(_ category: ExtensionUninstallCategory) -> Int64 {
        extensions.filter { $0.category == category }.reduce(0) { $0 + $1.size }
    }

    var selectedApps: [InstalledApplication] {
        apps.filter { selected.contains($0.id) }
    }

    var selectedAppSize: Int64 {
        selectedApps.reduce(0) { $0 + $1.size }
    }

    var selectedExtensionItems: [UninstallableExtension] {
        extensions.filter { selectedExtensions.contains($0.id) }
    }

    var selectedExtensionSize: Int64 {
        selectedExtensionItems.reduce(0) { $0 + $1.size }
    }

    // ---------------------------------------------------------------- 准备卸载

    /// 用户点"卸载"后先做一次只读核对，把应用与关联项列出来供勾选。
    func prepareApplicationUninstall() {
        let targets = selectedApps
        guard !targets.isEmpty, !busy, !scanning else { return }
        busy = true
        status = "正在检查关联项目…"
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let related = targets.map { ApplicationUninstaller.relatedItems(for: $0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.reviewTarget = ReviewTarget(apps: targets, related: related, extensions: [])
            }
        }
    }

    func prepareExtensionUninstall() {
        let targets = selectedExtensionItems
        guard !targets.isEmpty, !busy else { return }
        reviewTarget = ReviewTarget(apps: [], related: [], extensions: targets)
    }

    /// 执行卸载。选中路径集合由确认面板给出；已成功处理的路径不会重复处理。
    func execute(_ target: ReviewTarget, selectedPaths: [Set<String>]) {
        busy = true
        status = "正在移入废纸篓…"
        reviewTarget = nil

        if target.isExtension {
            let items = target.extensions
            DispatchQueue.global(qos: .utility).async { [weak self] in
                var results: [FileActionResult] = []
                for item in items {
                    let plan = ExtensionUninstaller.prepareUninstall([item])
                    results += plan.execute()
                }
                let summary = FileOperationPlan.summary(results)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy = false
                    self.refresh()
                    self.presentResult("清理结果", summary)
                }
            }
            return
        }

        let plans = zip(target.apps, target.related).map {
            ApplicationUninstaller.prepareUninstall($0.0, relatedItems: $0.1)
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var results: [FileActionResult] = []
            var completed = Set<String>()
            for (index, plan) in plans.enumerated() {
                // 同一路径可能被多个应用共享，只处理第一次出现。
                let paths = (index < selectedPaths.count ? selectedPaths[index] : []).subtracting(completed)
                let relatedPlan = FileOperationPlan(
                    items: plan.related.items.filter { paths.contains($0.url.path) },
                    rejected: plan.related.rejected.filter { paths.contains($0.url.path) })
                let selectedPlan = ApplicationUninstaller.UninstallPlan(
                    app: plan.app, application: plan.application, related: relatedPlan)
                let result = selectedPlan.execute()
                results += result
                completed.formUnion(result.filter(\.succeeded).map { $0.url.path })
            }
            let summary = FileOperationPlan.summary(results)
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                self.selected = []
                self.refresh()
                self.presentResult("卸载结果", summary)
            }
        }
    }

    private func presentResult(_ title: String, _ detail: String) {
        status = detail
        let alert = NSAlert()
        alert.messageText = L10n.text(title)
        alert.informativeText = L10n.text(detail)
        alert.addButton(withTitle: L10n.text("完成"))
        alert.runModal()
    }
}

// ============================================================================
// MARK: - 视图
// ============================================================================

struct LumenUninstallerView: View {
    @StateObject private var model = UninstallerPageModel()

    var body: some View {
        ModulePage(
            module: .uninstaller,
            subtitle: model.status,
            trailing: { actions },
            footer: { footer },
            content: { content }
        )
        .onAppear { if model.apps.isEmpty { model.refresh() } }
        .sheet(item: $model.reviewTarget) { target in
            UninstallReviewSheet(target: target) { paths in
                model.execute(target, selectedPaths: paths)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        if model.busy {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(L10n.text(model.status))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
        } else {
            Button(L10n.text("重新扫描")) { model.refresh() }
                .lumenButton(.secondary, icon: "arrow.clockwise")
                .disabled(model.scanning)
        }

        if model.mode == .applications {
            Button(L10n.text("卸载所选")) { model.prepareApplicationUninstall() }
                .lumenButton(.danger, icon: "trash")
                .disabled(model.selected.isEmpty || model.busy)
        } else {
            Button(L10n.text("清理所选")) { model.prepareExtensionUninstall() }
                .lumenButton(.danger, icon: "trash")
                .disabled(model.selectedExtensions.isEmpty || model.busy)
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            modeBar
            if model.mode == .applications { applicationGrid } else { extensionBrowser }
        }
    }

    private var modeBar: some View {
        ModuleToolbar {
            SegmentedBar(options: [("应用", UninstallerPageModel.Mode.applications),
                                   ("系统扩展", UninstallerPageModel.Mode.extensions)],
                         selection: $model.mode)

            if model.mode == .applications {
                SearchBox(placeholder: "搜索应用名称或标识", text: $model.search, width: 220)
                Spacer(minLength: Lumen.Metrics.s2)
                Text(L10n.format("已选 %{0} 个 · %{1}",
                                 arguments: [String(model.selected.count), CacheCleaner.formattedSize(model.selectedAppSize)]))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                Button(L10n.text(model.selected.count == model.visibleApps.count ? "取消全选" : "全选")) {
                    if model.selected.count == model.visibleApps.count {
                        model.selected.removeAll()
                    } else {
                        model.selected = Set(model.visibleApps.map(\.id))
                    }
                }
                .lumenButton(.plain, compact: true)
            } else {
                Spacer()
                Text(L10n.format("已选 %{0} 项 · %{1}",
                                 arguments: [String(model.selectedExtensions.count), CacheCleaner.formattedSize(model.selectedExtensionSize)]))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
        }
    }

    // ---------------------------------------------------------------- 应用网格

    private var applicationGrid: some View {
        ScrollView(.vertical, showsIndicators: true) {
            if model.visibleApps.isEmpty {
                EmptyState(symbol: model.scanning ? "magnifyingglass" : "shippingbox",
                           title: model.scanning ? "正在扫描应用…" : "没有匹配的应用",
                           detail: model.scanning ? nil : "换个关键词试试。")
                .frame(height: 300)
            } else {
                AdaptiveGrid(minimum: 224, spacing: 10) {
                    ForEach(model.visibleApps) { app in
                        AppCard(app: app, selected: model.selected.contains(app.id)) {
                            if model.selected.contains(app.id) {
                                model.selected.remove(app.id)
                            } else {
                                model.selected.insert(app.id)
                            }
                        }
                    }
                }
                .padding(.horizontal, Lumen.Metrics.pageInset)
                .padding(.bottom, Lumen.Metrics.s5)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }

    // ---------------------------------------------------------------- 扩展浏览

    private var extensionBrowser: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                NoticeBar(level: .info,
                          text: "系统扩展指安装文件、浏览器扩展、屏幕保护程序、设置面板、Internet 插件与小组件。移除后可能影响对应软件的功能。")

                categoryGrid

                if model.visibleExtensions.isEmpty {
                    EmptyState(symbol: "puzzlepiece.extension",
                               title: "这一类没有可清理的项目",
                               detail: "换个分类看看。")
                        .frame(height: 200)
                } else {
                    LumenPanel(categoryTitle, code: "\(model.visibleExtensions.count)", padding: 0) {
                        VStack(spacing: 0) {
                            ForEach(model.visibleExtensions) { item in
                                HStack(spacing: Lumen.Metrics.s3) {
                                    Toggle("", isOn: Binding(
                                        get: { model.selectedExtensions.contains(item.id) },
                                        set: { on in
                                            if on { model.selectedExtensions.insert(item.id) }
                                            else { model.selectedExtensions.remove(item.id) }
                                        }
                                    ))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)

                                    Text(item.name)
                                        .font(Lumen.Typo.dense())
                                        .foregroundStyle(Lumen.Palette.text)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)

                                    MonoText(text: item.url.path, size: 9.5, color: Lumen.Palette.textGhost)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(width: 240, alignment: .leading)

                                    MonoText(text: CacheCleaner.formattedSize(item.size), size: 11, color: Lumen.Palette.textMuted)
                                        .frame(width: 76, alignment: .trailing)

                                    IconAction(symbol: "folder", help: "在 Finder 中显示") {
                                        NSWorkspace.shared.activateFileViewerSelecting([item.url])
                                    }
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .hairlineBottom()
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s5)
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }

    private var categoryGrid: some View {
        AdaptiveGrid(minimum: 158, spacing: 9) {
            ForEach(ExtensionUninstallCategory.allCases) { category in
                Button {
                    model.category = category
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: category.symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(model.category == category ? Lumen.Palette.activeInk : Lumen.Palette.textFaint)
                            MicroText(category.title)
                            Spacer(minLength: 0)
                        }
                        MonoText(text: "\(model.categoryCount(category))", size: 15, weight: .light,
                                 color: model.category == category ? Lumen.Palette.activeInk : Lumen.Palette.text)
                        Text(CacheCleaner.formattedSize(model.categorySize(category)))
                            .font(Lumen.Typo.caption())
                            .foregroundStyle(Lumen.Palette.textFaint)
                    }
                    .padding(11)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(model.category == category ? Lumen.Palette.activeWash : Lumen.Palette.raised,
                                in: RoundedRectangle(cornerRadius: Lumen.Metrics.rPanel, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rPanel, style: .continuous)
                        .strokeBorder(model.category == category ? Lumen.Palette.active.opacity(0.35) : Lumen.Palette.hairline, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var categoryTitle: String {
        ExtensionUninstallCategory.allCases.first { $0 == model.category }?.title ?? ""
    }

    private var footer: some View {
        PageFooter(
            leading: model.status,
            tone: model.busy || model.scanning ? .caution : .active,
            trailing: model.mode == .applications
                ? ["\(model.apps.count) 个应用",
                   model.selected.isEmpty ? "未选择" : "已选 \(model.selected.count) 个"]
                : ["\(model.extensions.count) 个扩展",
                   model.selectedExtensions.isEmpty ? "未选择" : "已选 \(model.selectedExtensions.count) 项"]
        )
    }
}

// ============================================================================
// MARK: - 应用卡片
// ============================================================================

private struct AppCard: View {
    let app: InstalledApplication
    let selected: Bool
    let toggle: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Lumen.Metrics.s3) {
                AppGlyph(name: app.name, image: NSWorkspace.shared.icon(forFile: app.url.path), size: 34)

                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name)
                        .font(.system(size: 12.5 * Lumen.scale, weight: .medium))
                        .foregroundStyle(Lumen.Palette.text)
                        .lineLimit(1)
                    MonoText(text: CacheCleaner.formattedSize(app.size), size: 10.5, color: Lumen.Palette.textFaint)
                    Text(app.bundleID)
                        .font(Lumen.Typo.mono(9.5))
                        .foregroundStyle(Lumen.Palette.textGhost)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 0)

                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Lumen.Palette.active : Lumen.Palette.textGhost)
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Lumen.Palette.activeWash : Lumen.Palette.raised,
                        in: RoundedRectangle(cornerRadius: Lumen.Metrics.rPanel, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rPanel, style: .continuous)
                .strokeBorder(selected ? Lumen.Palette.active.opacity(0.45)
                                       : (hovering ? Lumen.Palette.hairlineHard : Lumen.Palette.hairline), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(L10n.text("在 Finder 中显示")) {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
        }
    }
}

// ============================================================================
// MARK: - 卸载确认面板
// ============================================================================

private struct UninstallReviewSheet: View {
    let target: UninstallerPageModel.ReviewTarget
    let confirm: ([Set<String>]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var checked: [Set<String>] = []

    private var totalRelatedSize: Int64 {
        target.related.flatMap { $0 }.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: target.isExtension ? "清理系统扩展" : "卸载应用",
                       eyebrow: "UNINSTALL / REVIEW",
                       subtitle: target.isExtension
                           ? L10n.format("将移除 %{0} 个项目", arguments: [String(target.extensions.count)])
                           : L10n.format("将卸载 %{0} 个应用", arguments: [String(target.apps.count)])) {
                Button(L10n.text("取消")) { dismiss() }
                    .lumenButton(.secondary)
            }

            NoticeBar(level: .caution,
                      text: target.isExtension
                          ? "所选项目将移入废纸篓，可从废纸篓恢复。移除后对应软件的功能可能受影响。"
                          : "应用及勾选的关联项将移入废纸篓。请先保存数据并退出这些应用。")
                .padding(.horizontal, Lumen.Metrics.pageInset)
                .padding(.bottom, Lumen.Metrics.s3)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                    if target.isExtension {
                        extensionList
                    } else {
                        ForEach(Array(target.apps.enumerated()), id: \.element.id) { index, app in
                            applicationSection(index: index, app: app)
                        }
                    }
                }
                .padding(.horizontal, Lumen.Metrics.pageInset)
                .padding(.bottom, Lumen.Metrics.s3)
            }
            .scrollContentBackground(.hidden)

            HStack(spacing: Lumen.Metrics.s3) {
                Text(summaryText)
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                Spacer()
                Button(L10n.text("取消")) { dismiss() }
                    .lumenButton(.secondary)
                Button(L10n.text(target.isExtension ? "确认清理" : "一键卸载")) {
                    confirm(checked)
                    dismiss()
                }
                .lumenButton(.danger, icon: "trash")
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .frame(height: 54)
            .background(Lumen.Palette.rail)
            .hairlineTop()
        }
        .frame(width: 620, height: 540)
        .background(Lumen.Palette.canvas)
        .onAppear {
            // 默认勾选全部关联项；用户可逐项取消。
            checked = target.related.map { Set($0.map(\.url.path)) }
        }
    }

    private var summaryText: String {
        if target.isExtension {
            let size = target.extensions.reduce(0) { $0 + $1.size }
            return L10n.format("共 %{0} 项 · %{1}",
                               arguments: [String(target.extensions.count), CacheCleaner.formattedSize(size)])
        }
        let appSize = target.apps.reduce(0) { $0 + $1.size }
        let checkedCount = checked.reduce(0) { $0 + $1.count }
        return L10n.format("应用 %{0} · 关联项 %{1} 项 · 合计 %{2}",
                           arguments: [CacheCleaner.formattedSize(appSize),
                                       String(checkedCount),
                                       CacheCleaner.formattedSize(appSize + totalRelatedSize)])
    }

    private var extensionList: some View {
        LumenPanel("待清理项目", code: "\(target.extensions.count)", padding: 0) {
            VStack(spacing: 0) {
                ForEach(target.extensions) { item in
                    HStack(spacing: Lumen.Metrics.s3) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                            .foregroundStyle(Lumen.Palette.textFaint)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name)
                                .font(Lumen.Typo.dense())
                                .foregroundStyle(Lumen.Palette.text)
                            MonoText(text: item.url.path, size: 9.5, color: Lumen.Palette.textGhost)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: Lumen.Metrics.s2)
                        MonoText(text: CacheCleaner.formattedSize(item.size), size: 11, color: Lumen.Palette.textMuted)
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .hairlineBottom()
                }
            }
        }
    }

    private func applicationSection(index: Int, app: InstalledApplication) -> some View {
        LumenPanel(app.name, code: CacheCleaner.formattedSize(app.size), padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: Lumen.Metrics.s3) {
                    AppGlyph(name: app.name, image: NSWorkspace.shared.icon(forFile: app.url.path), size: 20)
                    MonoText(text: app.url.path, size: 10, color: Lumen.Palette.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Pill("将卸载", tone: .danger)
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .hairlineBottom()

                let items = index < target.related.count ? target.related[index] : []
                if items.isEmpty {
                    Text(L10n.text("未发现可识别的关联项目。"))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: Lumen.Metrics.s3) {
                            Toggle("", isOn: Binding(
                                get: { index < checked.count && checked[index].contains(item.url.path) },
                                set: { on in
                                    guard index < checked.count else { return }
                                    if on { checked[index].insert(item.url.path) }
                                    else { checked[index].remove(item.url.path) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)

                            MonoText(text: item.url.path, size: 10, color: Lumen.Palette.textMuted)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            MonoText(text: CacheCleaner.formattedSize(item.size), size: 10.5, color: Lumen.Palette.textFaint)
                                .frame(width: 72, alignment: .trailing)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .hairlineBottom()
                    }
                }
            }
        }
    }
}
