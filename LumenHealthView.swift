import AppKit
import SwiftUI

// ============================================================================
//  系统健康检查
//  扫描编排、缓存清理计划、磁盘用量计算沿用原逻辑；
//  呈现方式改为「结论优先」：先给判断，再给数据。
// ============================================================================

/// 磁盘文件夹占用。原实现的 FolderUsage 是 DashboardWindow 内的私有类型，
/// 这里重新声明为内部类型，字段与语义保持一致。
struct HealthFolderUsage: Identifiable {
    let name: String
    let url: URL
    let bytes: Int64
    let incomplete: Bool
    var id: String { url.path }
}

@MainActor
final class HealthPageModel: ObservableObject {
    @Published var hardware: HardwareSnapshot?
    @Published var inspection: [MachineInspectionItem] = []
    @Published var snapshot: SystemSnapshot?
    @Published var userFolders: [HealthFolderUsage] = []
    @Published var applications: [InstalledApplication] = []
    @Published var startup: [StartupItem] = []
    @Published var caches: [CacheEntry] = []
    @Published var systemCacheEntries: [CacheEntry] = []
    @Published var totalSystemCaches: Int64 = 0
    @Published var totalSystemLibrary: Int64 = 0
    @Published var totalSystemStorage: Int64 = 0
    @Published var totalUserLibrary: Int64 = 0
    @Published var scanning = false
    @Published var phase = "准备检查"
    @Published var checkedAt: Date?
    @Published var cleaningMessage: String?
    @Published var benchmarks = HealthBenchmarkRunner()

    private var generation = 0
    private var scanInProgress = false

    var problems: [StartupItem] {
        startup.filter { item in
            ["无法解析", "不存在", "缺少", "未确认", "未读取"].contains { item.startupStatus.contains($0) }
        }
    }

    var cleanableCaches: [CacheEntry] { caches + systemCacheEntries }

    var totalCleanableSize: Int64 {
        cleanableCaches.reduce(0) { $0 + $1.size }
    }

    func reportBadge() {
        ModuleBadgeCenter.shared.report(.cacheCleaner, cleanableCaches.isEmpty ? nil : cleanableCaches.count)
    }

    // ---------------------------------------------------------------- 扫描

    func scan() {
        guard !scanInProgress else { return }
        scanInProgress = true
        scanning = true
        generation += 1
        let request = generation
        phase = "正在读取硬件与系统信息…"

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let hardware = HardwareSnapshot.read()
            let snapshot = SystemMonitor().sample()
            let inspection = MachineInspection.read()
            let folders = Self.measureUserFolders()
            let applications = ApplicationUninstaller.scan()
            let startup = StartupItemInspector.scan()

            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                self.hardware = hardware
                self.snapshot = snapshot
                self.inspection = inspection
                self.userFolders = folders
                self.applications = applications
                self.startup = startup
                self.phase = "正在统计缓存与系统占用…"
            }

            var userCaches: [CacheEntry] = []
            CacheCleaner.scanBatches { batch, _ in
                userCaches.append(contentsOf: batch)
                let sorted = userCaches.sorted { $0.size > $1.size }
                DispatchQueue.main.async {
                    guard let self, request == self.generation else { return }
                    self.caches = sorted
                }
            }

            var systemCaches: [CacheEntry] = []
            CacheCleaner.scanBatches(isSystem: true) { batch, _ in
                systemCaches.append(contentsOf: batch)
                let sorted = systemCaches.sorted { $0.size > $1.size }
                DispatchQueue.main.async {
                    guard let self, request == self.generation else { return }
                    self.systemCacheEntries = sorted
                }
            }

            let systemCachesTotal = Self.measure(URL(fileURLWithPath: "/Library/Caches"))
            let systemLibraryTotal = Self.measure(URL(fileURLWithPath: "/Library"))
            let systemStorageTotal = Self.measure(URL(fileURLWithPath: "/System/Library"))
            let userLibraryTotal = Self.measure(
                FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library"))

            DispatchQueue.main.async {
                guard let self, request == self.generation else { return }
                self.totalSystemCaches = systemCachesTotal
                self.totalSystemLibrary = systemLibraryTotal
                self.totalSystemStorage = systemStorageTotal
                self.totalUserLibrary = userLibraryTotal
                self.scanning = false
                self.scanInProgress = false
                self.checkedAt = Date()
                self.phase = "检查完成"
                self.reportBadge()
            }
        }
    }

    // ---------------------------------------------------------------- 容量计算

    /// 递归统计已分配大小。跳过符号链接，失败时标记不完整而不是当作 0。
    nonisolated static func measure(_ root: URL, excluding: Set<String> = []) -> Int64 {
        measureDetailed(root, excluding: excluding).bytes
    }

    nonisolated static func measureDetailed(_ root: URL, excluding: Set<String> = []) -> (bytes: Int64, incomplete: Bool) {
        var incomplete = false
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey,
                                         .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            errorHandler: { _, _ in incomplete = true; return true }
        ) else { return (0, true) }

        var bytes: Int64 = 0
        for case let url as URL in walker {
            if excluding.contains(url.path) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: keys) else {
                incomplete = true
                continue
            }
            if values.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            if values.isRegularFile == true {
                bytes += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
            }
        }
        return (bytes, incomplete)
    }

    /// 统计用户主目录下各标准文件夹的占用，按大小降序。
    nonisolated static func measureUserFolders() -> [HealthFolderUsage] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let names = ["Downloads", "Documents", "Desktop", "Movies", "Pictures", "Music",
                     "Library", "Applications", ".Trash"]
        return names.compactMap { name -> HealthFolderUsage? in
            let url = home.appendingPathComponent(name)
            guard url.standardizedFileURL.path.hasPrefix(home.standardizedFileURL.path) else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink != true
            else { return nil }
            let result = measureDetailed(url)
            return HealthFolderUsage(name: displayName(name), url: url, bytes: result.bytes, incomplete: result.incomplete)
        }
        .sorted { $0.bytes > $1.bytes }
    }

    private nonisolated static func displayName(_ name: String) -> String {
        if L10n.isEnglish {
            switch name {
            case "Downloads": return "Downloads"
            case "Documents": return "Documents"
            case "Desktop": return "Desktop"
            case "Movies": return "Movies"
            case "Pictures": return "Pictures"
            case "Music": return "Music"
            case "Library": return "Library"
            case "Applications": return "Applications"
            case ".Trash": return "Trash"
            default: return name
            }
        }
        switch name {
        case "Downloads": return "下载"
        case "Documents": return "文稿"
        case "Desktop": return "桌面"
        case "Movies": return "影片"
        case "Pictures": return "图片"
        case "Music": return "音乐"
        case "Library": return "资源库"
        case "Applications": return "应用程序"
        case ".Trash": return "废纸篓"
        default: return name
        }
    }

    // ---------------------------------------------------------------- 清理

    func clean(_ entries: [CacheEntry]) {
        guard !entries.isEmpty else { return }
        let plan = CacheCleaner.prepare(entries)
        let alert = NSAlert()
        alert.messageText = L10n.text("确认清理所列缓存？")
        alert.informativeText = L10n.text("下列项目将被移入废纸篓。建议先退出相关应用；清理后应用可能需要重新生成缓存。")
        alert.accessoryView = ProcessesModel.listView(
            entries.map { "\($0.name)\n\($0.url.path)  ·  \(CacheCleaner.formattedSize($0.size))" }
                .joined(separator: "\n\n"))
        alert.addButton(withTitle: L10n.text("取消"))
        alert.addButton(withTitle: L10n.text("移入废纸篓"))
        alert.buttons.last?.hasDestructiveAction = true
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        let total = entries.reduce(0) { $0 + $1.size }
        cleaningMessage = L10n.format("正在清理 %{0} 项（%{1}）…",
                                      arguments: [String(entries.count), CacheCleaner.formattedSize(total)])
        DispatchQueue.global(qos: .userInitiated).async {
            let results = plan.execute()
            let summary = FileOperationPlan.summary(results)
            DispatchQueue.main.async { [weak self] in
                self?.cleaningMessage = summary
                self?.scan()
            }
        }
    }
}

// ============================================================================
// MARK: - 性能测试
// ============================================================================

/// 原 HardwareBenchmarkModel 是 DashboardWindow 内的私有类型，
/// 这里以相同语义重新实现，保持顺序执行与取消语义。
@MainActor
final class HealthBenchmarkRunner: ObservableObject {
    @Published var running = false
    @Published var results: [HardwareBenchmark: [(String, String)]] = [:]
    @Published var messages: [HardwareBenchmark: String] = [:]
    private var task: Task<Void, Never>?
    private var hasStarted = false

    func startAllIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        running = true
        for kind in HardwareBenchmark.allCases {
            messages[kind] = "测试中…"
            results[kind] = nil
        }
        task = Task.detached(priority: .utility) { [weak self] in
            for kind in HardwareBenchmark.allCases {
                do {
                    let result = try kind.run()
                    await self?.finish(kind, result: result, message: "测试完成")
                } catch is CancellationError {
                    await self?.finish(kind, result: [], message: "测试已取消")
                    break
                } catch {
                    await self?.finish(kind, result: [], message: error.localizedDescription)
                }
            }
            await self?.finishAll()
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        hasStarted = false
        running = false
        results = [:]
        messages = [:]
    }

    private func finish(_ kind: HardwareBenchmark, result: [(String, String)], message: String) {
        results[kind] = result
        messages[kind] = message
    }

    private func finishAll() {
        running = false
        task = nil
        hasStarted = false
    }

    /// 全部用例是否已经跑过一轮（用于禁用重复触发）
    var hasRun: Bool { running || results.count == HardwareBenchmark.allCases.count }

    deinit { task?.cancel() }
}

// ============================================================================
// MARK: - 视图
// ============================================================================

struct LumenHealthView: View {
    @StateObject private var model = HealthPageModel()
    @State private var showingCacheSheet = false

    var body: some View {
        ModulePage(
            module: .cacheCleaner,
            subtitle: subtitle,
            trailing: { actions },
            footer: { footer },
            content: { content }
        )
        .onAppear { if model.checkedAt == nil { model.scan() } }
        .sheet(isPresented: $showingCacheSheet) {
            CacheCleanupSheet(model: model)
        }
    }

    private var subtitle: String {
        UnitFormat.joined([
            model.phase,
            model.checkedAt.map { "上次检查 \($0.formatted(date: .omitted, time: .standard))" } ?? ""
        ])
    }

    @ViewBuilder
    private var actions: some View {
        if model.scanning {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(L10n.text(model.phase))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
        } else {
            Button(L10n.text("重新检查")) { model.scan() }
                .lumenButton(.secondary, icon: "arrow.clockwise")
        }
        Button(L10n.text("清理缓存")) { showingCacheSheet = true }
            .lumenButton(.primary, icon: "trash")
            .disabled(model.cleanableCaches.isEmpty)
    }

    private var content: some View {
        ModuleForm(maxWidth: 860) {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s3) {
                summaryCards
                benchmarksPanel
                storagePanel
                cachePanel
                startupPanel
                if let message = model.cleaningMessage {
                    NoticeBar(level: .info, text: message)
                }
            }
        }
    }

    // ---------------------------------------------------------------- 结论卡

    private var summaryCards: some View {
        AdaptiveGrid(minimum: 196, spacing: 10) {
            conclusionCard(
                title: "设备",
                headline: model.hardware.map { "\($0.chip) · \($0.memory)" } ?? "读取中…",
                detail: model.hardware.map { UnitFormat.joined([$0.modelName, $0.coreCount, $0.architecture]) } ?? "",
                symbol: "laptopcomputer",
                tone: Lumen.Palette.active
            )
            conclusionCard(
                title: "可清理缓存",
                headline: CacheCleaner.formattedSize(model.totalCleanableSize),
                detail: "\(model.cleanableCaches.count) 个目录",
                symbol: "internaldrive",
                tone: model.totalCleanableSize > 2_000_000_000 ? Lumen.Palette.caution : Lumen.Palette.active
            )
            conclusionCard(
                title: "启动项异常",
                headline: "\(model.problems.count) 项",
                detail: model.problems.isEmpty ? "未发现明显异常" : model.problems.prefix(2).map(\.label).joined(separator: "、"),
                symbol: "bolt.badge.clock",
                tone: model.problems.isEmpty ? Lumen.Palette.active : Lumen.Palette.caution
            )
            ForEach(model.inspection.prefix(2)) { item in
                conclusionCard(
                    title: item.title,
                    headline: item.value,
                    detail: item.detail,
                    symbol: inspectionSymbol(item.status),
                    tone: inspectionTone(item.status)
                )
            }
        }
    }

    private func conclusionCard(title: String, headline: String, detail: String, symbol: String, tone: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Lumen.Palette.textFaint)
                MicroText(title)
            }
            Text(headline)
                .font(.system(size: 15 * Lumen.scale, weight: .semibold))
                .foregroundStyle(tone)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if !detail.isEmpty {
                Text(detail)
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .lumenPanel()
    }

    private func inspectionSymbol(_ status: MachineInspectionStatus) -> String {
        switch status {
        case .passed: return "checkmark.seal"
        case .attention: return "exclamationmark.triangle"
        case .informational: return "info.circle"
        case .unavailable: return "questionmark.circle"
        }
    }

    private func inspectionTone(_ status: MachineInspectionStatus) -> Color {
        switch status {
        case .passed: return Lumen.Palette.active
        case .attention: return Lumen.Palette.caution
        case .informational: return Lumen.Palette.textFaint
        case .unavailable: return Lumen.Palette.textGhost
        }
    }

    // ---------------------------------------------------------------- 性能测试

    private var benchmarksPanel: some View {
        LumenPanel("性能测试", code: "BENCHMARK") {
            VStack(alignment: .leading, spacing: Lumen.Metrics.s2) {
                ForEach(HardwareBenchmark.allCases, id: \.self) { kind in
                    BenchmarkRow(kind: kind, model: model.benchmarks)
                }
                HStack {
                    Text(L10n.text("测量值受当前负载、存储与网络环境影响，仅用于同机对比。"))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textFaint)
                    Spacer()
                    Button(L10n.text("开始测试")) { model.benchmarks.startAllIfNeeded() }
                        .lumenButton(.secondary, compact: true)
                        .disabled(model.benchmarks.hasRun)
                }
            }
        }
    }

    // ---------------------------------------------------------------- 存储

    private var storagePanel: some View {
        LumenPanel("存储占用", code: "STORAGE") {
            VStack(alignment: .leading, spacing: 2) {
                if let snapshot = model.snapshot {
                    DetailPair(key: "磁盘总量", value: UnitFormat.bytes(snapshot.diskTotal))
                    DetailPair(key: "已使用", value: UnitFormat.bytes(snapshot.diskUsed))
                    DetailPair(key: "可用空间", value: UnitFormat.bytes(snapshot.diskTotal > snapshot.diskUsed ? snapshot.diskTotal - snapshot.diskUsed : 0))
                }
                DetailPair(key: "系统缓存", value: CacheCleaner.formattedSize(model.totalSystemCaches))
                DetailPair(key: "系统资源库", value: CacheCleaner.formattedSize(model.totalSystemLibrary))
                DetailPair(key: "系统文件", value: CacheCleaner.formattedSize(model.totalSystemStorage))
                DetailPair(key: "用户资源库", value: CacheCleaner.formattedSize(model.totalUserLibrary))
            }

            if !model.userFolders.isEmpty {
                Divider().overlay(Lumen.Palette.hairlineSoft).padding(.vertical, Lumen.Metrics.s3)
                MicroText(L10n.format("用户文件夹占用前 %{0} 项", arguments: [String(min(6, model.userFolders.count))]))
                    .padding(.bottom, Lumen.Metrics.s2)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(model.userFolders.prefix(6)) { folder in
                        HStack(spacing: Lumen.Metrics.s3) {
                            Text(folder.name)
                                .font(Lumen.Typo.dense())
                                .foregroundStyle(Lumen.Palette.textMuted)
                                .frame(width: 110, alignment: .leading)
                            MeterBar(
                                fraction: model.userFolders.first.map { folder.bytes > 0 ? Double(folder.bytes) / Double($0.bytes) : 0 } ?? 0,
                                tone: Lumen.Palette.active,
                                height: 4
                            )
                            MonoText(text: CacheCleaner.formattedSize(folder.bytes), size: 11, color: Lumen.Palette.text)
                                .frame(width: 78, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- 缓存

    private var cachePanel: some View {
        LumenPanel("可清理缓存", code: "\(model.cleanableCaches.count)", trailing: AnyView(
            Button(L10n.text("查看并清理")) { showingCacheSheet = true }
                .lumenButton(.secondary, compact: true)
                .disabled(model.cleanableCaches.isEmpty)
        )) {
            if model.cleanableCaches.isEmpty {
                Text(L10n.text(model.scanning ? "正在扫描缓存…" : "未发现可清理的用户缓存。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.cleanableCaches.prefix(5)) { entry in
                        HStack(spacing: Lumen.Metrics.s3) {
                            AppGlyph(name: entry.name, image: NSWorkspace.shared.icon(forFile: entry.url.path), size: 17)
                            Text(entry.name)
                                .font(Lumen.Typo.dense())
                                .foregroundStyle(Lumen.Palette.text)
                                .lineLimit(1)
                            if entry.isSystem { Pill("系统", tone: .neutral) }
                            Spacer(minLength: Lumen.Metrics.s2)
                            MonoText(text: CacheCleaner.formattedSize(entry.size), size: 11, color: Lumen.Palette.textMuted)
                        }
                    }
                    if model.cleanableCaches.count > 5 {
                        Text(L10n.format("另有 %{0} 项，展开查看全部。", arguments: [String(model.cleanableCaches.count - 5)]))
                            .font(Lumen.Typo.caption())
                            .foregroundStyle(Lumen.Palette.textFaint)
                    }
                }
            }
        }
    }

    // ---------------------------------------------------------------- 启动项

    private var startupPanel: some View {
        LumenPanel("启动项", code: "\(model.startup.count)") {
            if model.startup.isEmpty {
                Text(L10n.text(model.scanning ? "正在扫描启动项…" : "未发现启动配置。"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    let issues = model.problems
                    if issues.isEmpty {
                        NoticeBar(level: .info, text: "未发现无法解析或目标缺失的用户启动配置。", symbol: "checkmark.circle")
                            .padding(.bottom, Lumen.Metrics.s2)
                    } else {
                        NoticeBar(level: .caution,
                                  text: L10n.format("发现 %{0} 项异常启动配置，可在启动项检查中处理。", arguments: [String(issues.count)]))
                            .padding(.bottom, Lumen.Metrics.s2)
                    }
                    ForEach(model.startup.prefix(4)) { item in
                        HStack(spacing: Lumen.Metrics.s3) {
                            Text(item.label)
                                .font(Lumen.Typo.dense())
                                .foregroundStyle(Lumen.Palette.text)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Pill(item.kind, tone: .neutral)
                            Pill(item.startupStatus, tone: model.problems.contains(where: { $0.id == item.id }) ? .caution : .neutral)
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        PageFooter(
            leading: model.scanning ? model.phase : (model.checkedAt.map { "检查完成 · \($0.formatted(date: .omitted, time: .standard))" } ?? "尚未检查"),
            tone: model.scanning ? .caution : .active,
            trailing: [
                "\(model.applications.count) 个应用",
                "\(model.startup.count) 个启动项",
                L10n.format("可清理 %{0}", arguments: [CacheCleaner.formattedSize(model.totalCleanableSize)])
            ]
        )
    }
}

// ============================================================================
// MARK: - 性能测试行
// ============================================================================

private struct BenchmarkRow: View {
    let kind: HardwareBenchmark
    @ObservedObject var model: HealthBenchmarkRunner

    var body: some View {
        HStack(spacing: Lumen.Metrics.s3) {
            Image(systemName: benchmarkSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Lumen.Palette.textFaint)
                .frame(width: 18)
            Text(kind.title)
                .font(Lumen.Typo.dense())
                .foregroundStyle(Lumen.Palette.text)
                .frame(width: 120, alignment: .leading)

            if let results = model.results[kind], !results.isEmpty {
                HStack(spacing: Lumen.Metrics.s3) {
                    ForEach(Array(results.prefix(3).enumerated()), id: \.offset) { _, pair in
                        HStack(spacing: 4) {
                            Text(pair.0)
                                .font(.system(size: 9.5))
                                .foregroundStyle(Lumen.Palette.textFaint)
                            MonoText(text: pair.1, size: 11)
                        }
                    }
                }
            } else if let message = model.messages[kind] {
                HStack(spacing: 6) {
                    if message == "测试中…" { ProgressView().controlSize(.small) }
                    Text(L10n.text(message))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(message == "测试中…" ? Lumen.Palette.textFaint : Lumen.Palette.cautionInk)
                }
            } else {
                Text(L10n.text("尚未测试"))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textGhost)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 30)
        .hairlineBottom()
    }

    private var benchmarkSymbol: String {
        switch kind {
        case .disk: return "internaldrive"
        case .memory: return "memorychip"
        case .localAI: return "cpu"
        }
    }
}

// ============================================================================
// MARK: - 缓存清理面板
// ============================================================================

private struct CacheCleanupSheet: View {
    @ObservedObject var model: HealthPageModel
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<URL> = []

    private var entries: [CacheEntry] {
        model.cleanableCaches.sorted { $0.size > $1.size }
    }

    private var selectedEntries: [CacheEntry] {
        entries.filter { selected.contains($0.id) }
    }

    private var selectedSize: Int64 {
        selectedEntries.reduce(0) { $0 + $1.size }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "清理缓存",
                       eyebrow: "CACHE / CLEANUP",
                       subtitle: "选中项目会被移入废纸篓，可从废纸篓恢复。") {
                Button(L10n.text("关闭")) { dismiss() }
                    .lumenButton(.secondary)
            }

            HStack(spacing: Lumen.Metrics.s3) {
                tile("可清理", CacheCleaner.formattedSize(model.totalCleanableSize), "\(entries.count) 个目录")
                tile("已选择", CacheCleaner.formattedSize(selectedSize), "\(selectedEntries.count) 个目录")
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s3)

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        HStack(spacing: Lumen.Metrics.s3) {
                            Toggle("", isOn: Binding(
                                get: { selected.contains(entry.id) },
                                set: { on in
                                    if on { selected.insert(entry.id) } else { selected.remove(entry.id) }
                                }
                            ))
                            .labelsHidden()
                            .toggleStyle(.checkbox)

                            AppGlyph(name: entry.name, image: NSWorkspace.shared.icon(forFile: entry.url.path), size: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.name)
                                    .font(Lumen.Typo.dense())
                                    .foregroundStyle(Lumen.Palette.text)
                                MonoText(text: entry.url.path, size: 9.5, color: Lumen.Palette.textGhost)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: Lumen.Metrics.s2)
                            if entry.isSystem { Pill("系统", tone: .neutral) }
                            MonoText(text: CacheCleaner.formattedSize(entry.size), size: 11, color: Lumen.Palette.textMuted)
                                .frame(width: 76, alignment: .trailing)
                        }
                        .padding(.horizontal, Lumen.Metrics.pageInset)
                        .frame(height: 44)
                        .hairlineBottom()
                    }
                }
            }
            .scrollContentBackground(.hidden)

            HStack(spacing: Lumen.Metrics.s3) {
                Button(L10n.text(selected.count == entries.count ? "取消全选" : "全选")) {
                    selected = selected.count == entries.count ? [] : Set(entries.map(\.id))
                }
                .lumenButton(.plain)

                Spacer()

                Button(L10n.text("清理所选")) {
                    let targets = selectedEntries
                    dismiss()
                    // 等 sheet 完全收起后再弹出确认，避免与废纸篓面板叠在一起。
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        model.clean(targets)
                    }
                }
                .lumenButton(.danger, icon: "trash")
                .disabled(selected.isEmpty)
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .frame(height: 52)
            .background(Lumen.Palette.rail)
            .hairlineTop()
        }
        .frame(width: 640, height: 520)
        .background(Lumen.Palette.canvas)
    }

    private func tile(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            MicroText(label)
            MonoText(text: value, size: 16, weight: .light)
            Text(detail)
                .font(Lumen.Typo.caption())
                .foregroundStyle(Lumen.Palette.textFaint)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenPanel()
    }
}
