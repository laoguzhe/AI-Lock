import AppKit
import SwiftUI

// ============================================================================
//  菜单栏总览弹窗
//  打开即读数：三格资源 + 网络曲线 + 模块入口。信息密度优先，不做装饰。
// ============================================================================

struct LumenOverviewView: View {
    @ObservedObject private var localizationState = LumenLanguageState.shared
    @ObservedObject private var language = LumenLanguageState.shared
    @ObservedObject private var monitoring = MonitoringService.shared
    @ObservedObject private var organizer = MenuBarOrganizer.shared
    @ObservedObject private var badgeCenter = ModuleBadgeCenter.shared

    @AppStorage("overview.fontScale.v1") private var fontSize = 1.0
    @AppStorage("overview.language") private var selectedEnglish = false
    @AppStorage("overview.followSystemLanguage") private var followSystemLanguage = true
    @AppStorage("appearance.mode") private var appearanceMode = "system"

    @State private var query = ""
    @State private var searchResults: [SearchResult] = []
    @State private var needsDiskAccess = false
    @State private var dockLockEnabled = DashboardWindow.dockLockEnabled
    @State private var editing = false
    @State private var dragging: String?
    @FocusState private var searchFocused: Bool

    private var snapshot: SystemSnapshot { monitoring.snapshot }
    private var history: [NetworkHistoryPoint] { NetworkHistory.shared.snapshot(now: snapshot.timestamp) }
    private let search = QuickSearch.shared
    private let alerts = ResourceAlerts()

    var body: some View {
        let _ = localizationState.revision
        let _ = language.revision
        VStack(alignment: .leading, spacing: 0) {
            topBar
            if !query.isEmpty { searchResultsSection }
            resourceMeters
            networkBlock
            moduleGrid
            bottomBar
        }
        .frame(width: 392)
        .background(Lumen.Palette.raised)
        .preferredColorScheme(DashboardWindow.preferredColorScheme)
        .onAppear { Lumen.scale = resolvedScale }
        .onChange(of: fontSize) { _, value in
            Lumen.scale = CGFloat(value > 3 ? value / 13 : value)
        }
    }

    private var resolvedScale: CGFloat {
        CGFloat(fontSize > 3 ? fontSize / 13 : fontSize)
    }

    // ---------------------------------------------------------------- 顶栏

    private var topBar: some View {
        HStack(spacing: 9) {
            StatusDot(tone: alertLevel, size: 6)
            MicroText(alertLevel == .active ? "总览 · 实时" : alertSummary)
            Spacer(minLength: 0)
            Button {
                followSystemLanguage = false
                selectedEnglish.toggle()
                NotificationCenter.default.post(name: L10n.changed, object: nil)
            } label: {
                Text(selectedEnglish ? "中" : "EN")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Lumen.Palette.textMuted)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.text("切换语言"))
            IconAction(symbol: appearanceMode == "dark" ? "moon.fill" : "sun.max.fill",
                       help: appearanceMode == "dark" ? "切换到浅色模式" : "切换到深色模式") {
                appearanceMode = appearanceMode == "dark" ? "light" : "dark"
                NSApp.appearance = DashboardWindow.preferredAppearance
                NotificationCenter.default.post(name: .appearanceModeChanged, object: nil)
            }
            IconAction(symbol: "slider.horizontal.3", help: "设置") {
                DashboardWindow.openPreferences()
            }
            IconAction(symbol: "power", help: "退出 AI Lock") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 40)
        .hairlineBottom()
    }

    private var alertLevel: PillTone {
        let active = alerts.evaluate(snapshot)
        if active.isEmpty { return .active }
        if active.contains(.disk) || active.contains(.cpu) { return .danger }
        return .caution
    }

    private var alertSummary: String {
        let active = alerts.evaluate(snapshot)
        let names = active.map { metric -> String in
            switch metric {
            case .cpu: return L10n.text("处理器")
            case .memory: return L10n.text("内存")
            case .disk: return L10n.text("磁盘")
            case .network: return L10n.text("网络")
            case .swap: return L10n.text("交换空间")
            case .battery: return L10n.text("电池")
            case .thermal: return L10n.text("温度")
            case .camera: return L10n.text("摄像头")
            case .microphone: return L10n.text("麦克风")
            }
        }
        return names.isEmpty ? L10n.text("总览 · 实时") : L10n.text("留意：") + names.joined(separator: L10n.isEnglish ? ", " : "、")
    }

    // ---------------------------------------------------------------- 搜索

    private var searchResultsSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            if needsDiskAccess {
                Button(action: SearchDiskAccess.openSettings) {
                    Label(L10n.text("文件访问被系统拦截，点此授权"), systemImage: "externaldrive.badge.exclamationmark")
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.cautionInk)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 4)
                .padding(.vertical, 3)
            }
            ForEach(searchResults.prefix(5)) { result in
                Button {
                    search.open(result)
                    search.cancel()
                    query = ""
                    searchResults = []
                } label: {
                    HStack(spacing: 8) {
                        Image(nsImage: result.icon)
                            .resizable().scaledToFit().frame(width: 20, height: 20)
                        Text(L10n.text(result.title))
                            .font(Lumen.Typo.dense())
                            .foregroundStyle(Lumen.Palette.text)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(L10n.text(result.typeLabel))
                            .font(Lumen.Typo.caption())
                            .foregroundStyle(Lumen.Palette.textFaint)
                    }
                    .padding(.horizontal, 8)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 6)
    }

    // ---------------------------------------------------------------- 资源

    private var resourceMeters: some View {
        VStack(spacing: 0) {
            meterRow(
                title: "处理器",
                symbol: "cpu",
                fraction: snapshot.cpuUsage,
                value: String(format: "%.0f%%", snapshot.cpuUsage * 100),
                tone: snapshot.cpuUsage * 100 >= alerts.threshold(for: .cpu) ? Lumen.Palette.danger : Lumen.Palette.active,
                alert: snapshot.cpuUsage * 100 >= alerts.threshold(for: .cpu)
            )
            meterRow(
                title: "内存",
                symbol: "memorychip",
                fraction: memoryFraction,
                value: String(format: "%.0f%%", memoryFraction * 100),
                tone: memoryAlert ? Lumen.Palette.caution : Lumen.Palette.active,
                alert: memoryAlert
            )
            meterRow(
                title: "磁盘",
                symbol: "internaldrive",
                fraction: diskFraction,
                value: diskLow ? UnitFormat.bytes(snapshot.diskTotal > snapshot.diskUsed ? snapshot.diskTotal - snapshot.diskUsed : 0) + " " + L10n.text("可用") : String(format: "%.0f%%", diskFraction * 100),
                tone: diskFraction >= 0.9 ? Lumen.Palette.danger : Lumen.Palette.active,
                alert: diskFraction >= 0.9
            )
            if let battery = snapshot.batteryPercent, battery <= 30 {
                meterRow(
                    title: "电池",
                    fraction: Double(battery) / 100,
                    value: "\(battery)%",
                    tone: battery <= 20 ? Lumen.Palette.danger : Lumen.Palette.caution,
                    alert: true
                )
            }
        }
        .padding(.horizontal, 15)
        .padding(.top, 6)
        .padding(.bottom, 9)
    }

    private var memoryFraction: Double {
        snapshot.memoryTotal > 0 ? Double(snapshot.memoryUsed) / Double(snapshot.memoryTotal) : 0
    }
    private var diskFraction: Double {
        snapshot.diskTotal > 0 ? Double(snapshot.diskUsed) / Double(snapshot.diskTotal) : 0
    }
    private var memoryAlert: Bool {
        snapshot.memoryPressure == "偏高" || snapshot.memoryPressure == "严重"
            || memoryFraction * 100 >= alerts.threshold(for: .memory)
    }
    private var diskLow: Bool {
        let free = snapshot.diskTotal > snapshot.diskUsed ? snapshot.diskTotal - snapshot.diskUsed : 0
        guard snapshot.diskTotal > 0 else { return false }
        return Double(free) / Double(snapshot.diskTotal) * 100 <= alerts.threshold(for: .diskFreePercent)
    }

    private func meterRow(title: String, symbol: String? = nil, fraction: Double, value: String, tone: Color, alert: Bool) -> some View {
        HStack(spacing: 11) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Lumen.Palette.textFaint)
                        .frame(width: 13)
                }
                Text(L10n.text(title))
                    .font(Lumen.Typo.dense())
                    .foregroundStyle(Lumen.Palette.textMuted)
            }
            .frame(width: 76, alignment: .leading)
            MeterBar(fraction: fraction, tone: tone)
            MonoText(text: value,
                     size: 11.5,
                     weight: alert ? .semibold : .regular,
                     color: alert ? tone : Lumen.Palette.text)
                .frame(width: 76, alignment: .trailing)
        }
        .padding(.vertical, 8)
        .hairlineBottom()
    }

    // ---------------------------------------------------------------- 网络

    private var networkBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MicroText("网络")
                Spacer(minLength: 0)
                let down = UnitFormat.rateParts(Double(snapshot.networkDownload))
                let up = UnitFormat.rateParts(Double(snapshot.networkUpload))
                HStack(spacing: 4) {
                    Text("↓").font(.system(size: 10, weight: .bold)).foregroundStyle(Lumen.Palette.downlink)
                    MonoText(text: down.value, size: 10.5, weight: .semibold)
                    Text(down.unit).font(.system(size: 9.5)).foregroundStyle(Lumen.Palette.textFaint)
                }
                HStack(spacing: 4) {
                    Text("↑").font(.system(size: 10, weight: .bold)).foregroundStyle(Lumen.Palette.activeInk)
                    MonoText(text: up.value, size: 10.5, weight: .semibold)
                    Text(up.unit).font(.system(size: 9.5)).foregroundStyle(Lumen.Palette.textFaint)
                }
            }
            // 历史记录保存的是上下行合计速率，因此只画单条曲线；
            // 瞬时上下行数值在上方以数字单独给出。
            TrafficSparkline(samples: history.map(\.bytesPerSecond), secondary: nil)
                .frame(height: 38)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .lumenPanel(radius: 8, fill: Lumen.Palette.sunken)
        .padding(.horizontal, 15)
        .padding(.bottom, 12)
    }

    // ---------------------------------------------------------------- 模块

    private var moduleGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 4), spacing: 3) {
            ForEach(visibleModules, id: \.rawValue) { module in
                ModuleTile(
                    module: module,
                    editing: editing,
                    badge: module == .files ? L10n.text("待上线") : badgeCenter.badges[module.rawValue],
                    dot: moduleDot(module),
                    action: { handleTap(module) },
                    onHide: { hideModule(module) }
                )
                .onDrag {
                    dragging = module.rawValue
                    return NSItemProvider(object: module.rawValue as NSString)
                }
                .onDrop(of: [.text], delegate: ModuleDropDelegate(
                    target: module.rawValue,
                    dragging: $dragging,
                    order: orderedModuleIDs,
                    commit: { commitOrder($0) }
                ))
            }
        }
        .padding(.horizontal, 11)
        .padding(.bottom, 12)
    }

    private func handleTap(_ module: DashboardWindow.Module) {
        if editing { return }
        switch module {
        case .dockLock:
            dockLockEnabled = DashboardWindow.toggleDockLock()
        case .menuBarOrganizer:
            organizer.toggleEnabled()
        case .preferences:
            DashboardWindow.openPreferences()
        default:
            _ = DashboardWindow.open(module)
        }
    }

    private func moduleDot(_ module: DashboardWindow.Module) -> PillTone? {
        switch module {
        case .dockLock: return dockLockEnabled ? .active : nil
        case .menuBarOrganizer: return organizer.enabled ? .active : nil
        default: return nil
        }
    }

    // ---------------------------------------------------------------- 数据

    private var orderedModuleIDs: [String] {
        let settings = AppSettings.shared
        let known = Set(ModuleCatalog.all.map(\.rawValue))
        var result = settings.orderedModuleIDs.filter { known.contains($0) }
        for module in ModuleCatalog.all where !result.contains(module.rawValue) {
            result.append(module.rawValue)
        }
        return result
    }

    private var visibleModules: [DashboardWindow.Module] {
        let visible: Set<String>
        if let configured = AppSettings.shared.visibleModuleIDs {
            // nil = 用户从未配置（默认全显）；空数组 = 用户明确隐藏全部。
            visible = Set(configured)
        } else {
            visible = Set(ModuleCatalog.all.map(\.rawValue))
        }
        let byID = Dictionary(uniqueKeysWithValues: ModuleCatalog.all.map { ($0.rawValue, $0) })
        return orderedModuleIDs.compactMap { visible.contains($0) ? byID[$0] : nil }
    }

    private func commitOrder(_ ids: [String]) {
        AppSettings.shared.orderedModuleIDs = ids
    }

    private func hideModule(_ module: DashboardWindow.Module) {
        AppSettings.shared.visibleModuleIDs = visibleModules
            .filter { $0 != module }
            .map(\.rawValue)
    }

    // ---------------------------------------------------------------- 底栏

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 7) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Lumen.Palette.textFaint)
                    TextField(L10n.text("搜索应用、文件或快捷操作"), text: $query)
                        .textFieldStyle(.plain)
                        .font(Lumen.Typo.dense())
                        .focused($searchFocused)
                        .onChange(of: query) { _, value in
                            search.search(value) { results in
                                searchResults = results
                                needsDiskAccess = search.requiresFullDiskAccess
                            }
                        }
                        .onSubmit {
                            if let first = searchResults.first { search.open(first); query = ""; searchResults = [] }
                        }
                }
                .padding(.horizontal, 9)
                .frame(height: 28)
                .lumenPanel(radius: 6)

                Button { searchFocused = true } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                }
                .lumenButton(.secondary, compact: true)
                .frame(width: 40)
                .help(L10n.text("搜索"))
            }
        }
        .padding(.horizontal, 15)
        .padding(.bottom, 13)
    }
}

// ============================================================================
// MARK: - 模块磁贴
// ============================================================================

private struct ModuleTile: View {
    let module: DashboardWindow.Module
    let editing: Bool
    let badge: String?
    let dot: PillTone?
    let action: () -> Void
    let onHide: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 7) {
                    Image(systemName: ModuleCatalog.symbol(module))
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(hovering ? Lumen.Palette.activeInk : Lumen.Palette.textMuted)
                        .frame(height: 20)
                    Text(L10n.text(ModuleCatalog.shortTitle(module)))
                        .font(.system(size: 10.5 * Lumen.scale))
                        .foregroundStyle(Lumen.Palette.textMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .padding(.horizontal, 2)
                .background(hovering ? Lumen.Palette.activeWash : .clear,
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .contentShape(Rectangle())

                if editing {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Lumen.Palette.danger)
                        .padding(4)
                        .onTapGesture { onHide() }
                } else if let dot {
                    StatusDot(tone: dot, size: 5)
                        .overlay(Circle().stroke(Lumen.Palette.raised, lineWidth: 1.5).frame(width: 8, height: 8))
                        .padding(9)
                } else if let badge {
                    MonoText(text: badge, size: 8.5, color: Lumen.Palette.textGhost)
                        .padding(8)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.text(module.displayTitle))
    }
}

// ============================================================================
// MARK: - 拖拽排序
// ============================================================================

private struct ModuleDropDelegate: DropDelegate {
    let target: String
    @Binding var dragging: String?
    let order: [String]
    let commit: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target,
              let from = order.firstIndex(of: dragging),
              let to = order.firstIndex(of: target) else { return }
        var updated = order
        updated.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        commit(updated)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}
