import AppKit
import SwiftUI

// ============================================================================
//  统一窗口外壳
//  左侧固定导航 + 右侧数据面。所有模块共享同一个窗口，切换模块不丢状态。
// ============================================================================

/// 侧栏导航的分组。分组是界面概念，不影响 Module 的持久化值。
struct ModuleGroup: Identifiable {
    let id: String
    let title: String
    let modules: [DashboardWindow.Module]
}

enum ModuleCatalog {
    /// 侧栏顺序。这里同时是"模块在界面上的自然顺序"的唯一定义。
    static let groups: [ModuleGroup] = [
        ModuleGroup(id: "monitor", title: "监控", modules: [
            .cacheCleaner, .processes, .network, .networkDiagnostics
        ]),
        ModuleGroup(id: "tools", title: "工具", modules: [
            .files, .clipboard, .uninstaller, .launchItems, .logs
        ]),
        ModuleGroup(id: "screen", title: "屏幕", modules: [
            .screenRecorder, .displayBrightness, .dockLock, .menuBarOrganizer
        ]),
        ModuleGroup(id: "system", title: "系统", modules: [
            .settings, .preferences
        ])
    ]

    static var all: [DashboardWindow.Module] { groups.flatMap(\.modules) }

    /// 模块的短标题（侧栏用）
    static func shortTitle(_ module: DashboardWindow.Module) -> String {
        switch module {
        case .cacheCleaner:       return "系统健康"
        case .processes:          return "进程"
        case .network:            return "网络活动"
        case .networkDiagnostics: return "网络诊断"
        case .files:              return "文件活动"
        case .clipboard:          return "剪贴板"
        case .uninstaller:        return "卸载与清理"
        case .launchItems:        return "启动项"
        case .logs:               return "应用日志"
        case .screenRecorder:     return "录屏"
        case .displayBrightness:  return "显示器"
        case .dockLock:           return "程序坞锁定"
        case .menuBarOrganizer:   return "菜单栏收纳"
        case .settings:           return "监控预警"
        case .preferences:        return "设置"
        case .search, .launcher:  return "快捷搜索"
        }
    }

    static func symbol(_ module: DashboardWindow.Module) -> String {
        switch module {
        case .cacheCleaner:       return "stethoscope"
        case .processes:          return "cpu"
        case .network:            return "network"
        case .networkDiagnostics: return "dot.radiowaves.left.and.right"
        case .files:              return "doc.text.magnifyingglass"
        case .clipboard:          return "doc.on.clipboard"
        case .uninstaller:        return "shippingbox"
        case .launchItems:        return "bolt.badge.clock"
        case .logs:               return "list.bullet.rectangle"
        case .screenRecorder:     return "record.circle"
        case .displayBrightness:  return "sun.max"
        case .dockLock:           return "dock.rectangle"
        case .menuBarOrganizer:   return "menubar.rectangle"
        case .settings:           return "bell.badge"
        case .preferences:        return "slider.horizontal.3"
        case .search, .launcher:  return "magnifyingglass"
        }
    }

    /// 模块编号，用于页头 "MODULE 02 / PROCESSES" 这类标识
    static func code(_ module: DashboardWindow.Module) -> String {
        switch module {
        case .cacheCleaner:       return "SYS-01"
        case .processes:          return "PRO-02"
        case .network:            return "NET-03"
        case .networkDiagnostics: return "NET-04"
        case .files:              return "FILE-05"
        case .clipboard:          return "CLP-06"
        case .uninstaller:        return "UNI-07"
        case .launchItems:        return "STA-08"
        case .logs:               return "LOG-09"
        case .screenRecorder:     return "REC-10"
        case .displayBrightness:  return "DIS-11"
        case .dockLock:           return "DCK-12"
        case .menuBarOrganizer:   return "MBO-13"
        case .settings:           return "ALT-16"
        case .preferences:        return "SET-14"
        case .search, .launcher:  return "QRY-15"
        }
    }

    /// 页头下方的模块编号栏文字
    static func eyebrow(_ module: DashboardWindow.Module) -> String {
        "MODULE \(code(module)) / \(englishName(module).uppercased())"
    }

    static func englishName(_ module: DashboardWindow.Module) -> String {
        switch module {
        case .cacheCleaner:       return "System Health"
        case .processes:          return "Processes"
        case .network:            return "Network Activity"
        case .networkDiagnostics: return "Net Diagnostics"
        case .files:              return "File Activity"
        case .clipboard:          return "Clipboard"
        case .uninstaller:        return "Uninstaller"
        case .launchItems:        return "Startup Items"
        case .logs:               return "Application Log"
        case .screenRecorder:     return "Screen Recorder"
        case .displayBrightness:  return "Displays"
        case .dockLock:           return "DockLock"
        case .menuBarOrganizer:   return "Menu Bar"
        case .settings:           return "Alerts"
        case .preferences:        return "Preferences"
        case .search, .launcher:  return "Quick Search"
        }
    }

}

/// 侧栏徽标中心。
/// 计数由各页面在自己加载完数据后上报 —— 侧栏不主动去抓数据，
/// 避免为了显示一个小数字而启动本不该启动的采样。
final class ModuleBadgeCenter: ObservableObject {
    static let shared = ModuleBadgeCenter()
    @Published private(set) var badges: [String: String] = [:]

    private init() {}

    func report(_ module: DashboardWindow.Module, _ value: Int?) {
        let key = module.rawValue
        let text = (value ?? 0) > 0 ? Self.format(value ?? 0) : nil
        guard badges[key] != text else { return }
        if let text { badges[key] = text } else { badges.removeValue(forKey: key) }
    }

    func report(_ module: DashboardWindow.Module, text: String?) {
        let key = module.rawValue
        guard badges[key] != text else { return }
        if let text { badges[key] = text } else { badges.removeValue(forKey: key) }
    }

    private static func format(_ value: Int) -> String {
        value >= 1000 ? String(format: "%.1fk", Double(value) / 1000) : "\(value)"
    }
}

// ============================================================================
// MARK: - 侧栏
// ============================================================================

/// AI Lock 的 logo。build.sh 把 icon.png 复制为应用包内的 Contents/Resources/StatusIcon.png，
/// 与菜单栏图标使用同一份文件。直接从 Xcode 运行时包内没有该文件，调用方需要自行回退。
enum AILockLogo {
    static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "StatusIcon", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

struct LumenSidebar: View {
    @Binding var selection: DashboardWindow.Module
    @ObservedObject private var organizer = MenuBarOrganizer.shared
    @ObservedObject private var badgeCenter = ModuleBadgeCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 品牌区：与窗口标题栏衔接
            HStack(spacing: Lumen.Metrics.s2) {
                brandMark
                Text("AI Lock")
                    .font(.system(size: 12.5 * Lumen.scale, weight: .semibold))
                    .foregroundStyle(Lumen.Palette.text)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: Lumen.Metrics.hToolbar + 2)
            .hairlineBottom()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ModuleCatalog.groups) { group in
                        MicroText(group.title)
                            .padding(.horizontal, 16)
                            .padding(.top, 14)
                            .padding(.bottom, 6)

                        ForEach(group.modules, id: \.rawValue) { module in
                            SidebarItem(
                                module: module,
                                selected: module == selection,
                                badge: badgeCenter.badges[module.rawValue],
                                trailingDot: trailingDot(for: module)
                            ) {
                                selection = module
                            }
                        }
                    }
                }
                .padding(.bottom, Lumen.Metrics.s4)
            }
        }
        .frame(width: Lumen.Metrics.railWidth)
        .frame(maxHeight: .infinity)
        .background(Lumen.Palette.rail)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Lumen.Palette.hairline).frame(width: 1)
        }
    }

    /// 常驻状态指示：只在"某个开关正开着"时点亮
    private var brandMark: some View {
        Group {
            if let logo = AILockLogo.image {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Lumen.Palette.active)
            }
        }
    }

    /// 常驻状态指示：只在"某个开关正开着"时点亮
    private func trailingDot(for module: DashboardWindow.Module) -> PillTone? {
        switch module {
        case .dockLock:
            return DashboardWindow.dockLockEnabled ? .active : nil
        case .menuBarOrganizer:
            return organizer.enabled ? .active : nil
        default:
            return nil
        }
    }
}

private struct SidebarItem: View {
    let module: DashboardWindow.Module
    let selected: Bool
    let badge: String?
    let trailingDot: PillTone?
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: ModuleCatalog.symbol(module))
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Lumen.Palette.activeInk : Lumen.Palette.textFaint)
                    .frame(width: 16)

                Text(L10n.text(ModuleCatalog.shortTitle(module)))
                    .font(.system(size: 12 * Lumen.scale, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Lumen.Palette.text : Lumen.Palette.textMuted)
                    .lineLimit(1)

                Spacer(minLength: Lumen.Metrics.s1)

                if let trailingDot {
                    StatusDot(tone: trailingDot, size: 5)
                }
                if let badge {
                    MonoText(text: badge, size: 10, color: selected ? Lumen.Palette.activeInk : Lumen.Palette.textFaint)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 30)
            .background(background, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Lumen.Palette.hairline, lineWidth: selected ? 0.5 : 0)
                }
            }
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.text(module.displayTitle))
    }

    private var background: Color {
        if selected { return Lumen.Palette.raised }
        if hovering { return Lumen.Palette.rowHover }
        return .clear
    }
}

// ============================================================================
// MARK: - 外壳
// ============================================================================

struct LumenShell<Content: View>: View {
    @Binding var selection: DashboardWindow.Module
    @ViewBuilder var content: (DashboardWindow.Module) -> Content

    var body: some View {
        HStack(spacing: 0) {
            LumenSidebar(selection: $selection)
            content(selection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Lumen.Palette.canvas)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Lumen.Palette.canvas)
        .preferredColorScheme(DashboardWindow.preferredColorScheme)
        .environment(\.lumenScale, Lumen.scale)
    }
}

private struct LumenScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var lumenScale: CGFloat {
        get { self[LumenScaleKey.self] }
        set { self[LumenScaleKey.self] = newValue }
    }
}

// ============================================================================
// MARK: - 页面骨架
//  所有模块页面都用它：标题区 + 内容 + 页脚。保证跨模块节奏一致。
// ============================================================================

struct ModulePage<Trailing: View, Footer: View, Content: View>: View {
    @ObservedObject private var language = LumenLanguageState.shared
    let module: DashboardWindow.Module
    let subtitle: String?
    let trailing: () -> Trailing
    let footer: () -> Footer
    let content: () -> Content

    init(module: DashboardWindow.Module,
         subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder footer: @escaping () -> Footer,
         @ViewBuilder content: @escaping () -> Content) {
        self.module = module
        self.subtitle = subtitle
        self.trailing = trailing
        self.footer = footer
        self.content = content
    }

    var body: some View {
        let _ = language.revision
        VStack(spacing: 0) {
            PageHeader(title: module.displayTitle,
                       eyebrow: ModuleCatalog.eyebrow(module),
                       subtitle: subtitle,
                       trailing: trailing)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer()
        }
    }
}

extension ModulePage where Trailing == EmptyView, Footer == EmptyView {
    /// 没有右侧操作、也没有页脚时的便捷构造。
    init(module: DashboardWindow.Module,
         subtitle: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(module: module, subtitle: subtitle, trailing: { EmptyView() }, footer: { EmptyView() }, content: content)
    }
}

extension ModulePage where Footer == EmptyView {
    init(module: DashboardWindow.Module,
         subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(module: module, subtitle: subtitle, trailing: trailing, footer: { EmptyView() }, content: content)
    }
}

extension ModulePage where Trailing == EmptyView {
    init(module: DashboardWindow.Module,
         subtitle: String? = nil,
         @ViewBuilder footer: @escaping () -> Footer,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(module: module, subtitle: subtitle, trailing: { EmptyView() }, footer: footer, content: content)
    }
}

// ============================================================================
// MARK: - 工具栏容器
// ============================================================================

/// 页面二级工具栏：搜索、筛选、右侧说明。带下边距，与表格拉开呼吸。
struct ModuleToolbar<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        HStack(spacing: Lumen.Metrics.s2) {
            content()
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .padding(.bottom, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// ============================================================================
// MARK: - 内容区包裹
// ============================================================================

/// 表格类页面用：撑满剩余高度并裁掉溢出。
struct ModuleTableArea<Content: View>: View {
    @ViewBuilder var content: () -> Content

    init(@ViewBuilder content: @escaping () -> Content) {
        self.content = content
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 0) {
                content()
            }
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }
}

/// 表单类页面用：带内边距的可滚动区域。
struct ModuleForm<Content: View>: View {
    var maxWidth: CGFloat = 720
    @ViewBuilder var content: () -> Content

    init(maxWidth: CGFloat = 720, @ViewBuilder content: @escaping () -> Content) {
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .padding(.horizontal, Lumen.Metrics.pageInset)
            .padding(.bottom, Lumen.Metrics.s6)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }
}

// ============================================================================
// MARK: - 网格
// ============================================================================

/// 自适应卡片网格，用于应用列表、系统扩展等。
struct AdaptiveGrid<Content: View>: View {
    var minimum: CGFloat = 168
    var spacing: CGFloat = 12
    @ViewBuilder var content: () -> Content

    init(minimum: CGFloat = 168, spacing: CGFloat = 12, @ViewBuilder content: @escaping () -> Content) {
        self.minimum = minimum
        self.spacing = spacing
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minimum, maximum: minimum * 2.4), spacing: spacing)],
                  alignment: .leading,
                  spacing: spacing) {
            content()
        }
    }
}

// ============================================================================
// MARK: - 加载中
// ============================================================================

struct LoadingRow: View {
    let text: String
    var body: some View {
        HStack(spacing: Lumen.Metrics.s2) {
            ProgressView().controlSize(.small)
            Text(L10n.text(text))
                .font(Lumen.Typo.caption())
                .foregroundStyle(Lumen.Palette.textFaint)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .padding(.vertical, Lumen.Metrics.s3)
    }
}

/// 顶部的细进度条，用于长期运行的任务（扫描、诊断）
struct ActivityBar: View {
    var active: Bool
    var body: some View {
        GeometryReader { proxy in
            if active {
                Rectangle()
                    .fill(Lumen.Palette.active)
                    .frame(width: proxy.size.width * 0.3)
                    .clipShape(Capsule())
                    .offset(x: proxy.size.width * 0.7)
                    .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: active)
            }
        }
        .frame(height: 2)
        .opacity(active ? 1 : 0)
    }
}
