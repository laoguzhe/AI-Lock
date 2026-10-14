import AppKit
import SwiftUI

/// 让普通 SwiftUI 模块在 L10n.changed 后重新计算 L10n.text(...) 文案。
/// 只驱动 body 更新，不重置页面 identity 或本地筛选状态。
final class LumenLanguageState: ObservableObject {
    static let shared = LumenLanguageState()
    @Published private(set) var revision = 0
    private var observer: NSObjectProtocol?

    func refresh() {
        revision &+= 1
    }

    private init() {
        observer = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.refresh()
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}

// ============================================================================
//  LUMEN 设计系统
//  明亮精密：浅色为主，深色完整对等。发丝线分层，等宽数字承载读数，
//  单一青绿只表示"正在运行"。这里是全项目唯一的视觉真相来源。
// ============================================================================

enum Lumen {

    // ------------------------------------------------------------------------
    // MARK: - 色彩
    // ------------------------------------------------------------------------

    /// 自适应颜色：一次声明浅色与深色两个取值，随外观自动切换。
    private static func adaptive(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    enum Palette {
        // 底层
        /// 窗口内容底色
        static let canvas      = adaptive(hex(0xFBFBFC), hex(0x15181D))
        /// 侧栏 / 页脚等下沉区域
        static let rail        = adaptive(hex(0xF4F5F7), hex(0x12151A))
        /// 浮起：卡片、选中行、输入框
        static let raised      = adaptive(hex(0xFFFFFF), hex(0x1B1F25))
        /// 更深的凹陷：代码块、日志窗
        static let sunken      = adaptive(hex(0xF0F2F5), hex(0x0E1114))
        /// 窗口外的画布（用于预览与分组底板）
        static let backdrop    = adaptive(hex(0xEDEFF2), hex(0x0B0D10))

        // 文字
        static let text        = adaptive(hex(0x1A1F27), hex(0xE7EAEF))
        static let textMuted   = adaptive(hex(0x4E5764), hex(0x99A2B0))
        static let textFaint   = adaptive(hex(0x8B93A0), hex(0x626B79))
        static let textGhost   = adaptive(hex(0xA8AFB9), hex(0x4C545F))

        // 描边
        static let hairline    = adaptive(hex(0x141A22, alpha: 0.10), hex(0xFFFFFF, alpha: 0.09))
        static let hairlineSoft = adaptive(hex(0x141A22, alpha: 0.055), hex(0xFFFFFF, alpha: 0.05))
        static let hairlineHard = adaptive(hex(0x141A22, alpha: 0.16), hex(0xFFFFFF, alpha: 0.14))

        // 语义色 —— 只表达三种含义，不做装饰
        /// 正在运行 / 正常 / 主操作
        static let active      = adaptive(hex(0x12A88F), hex(0x23C3AC))
        /// 活性色的深色强调（浅色模式用于文字与图标）
        static let activeInk   = adaptive(hex(0x0C7D6E), hex(0x23C3AC))
        /// 活性色的浅底
        static let activeWash  = adaptive(hex(0x12A88F, alpha: 0.10), hex(0x23C3AC, alpha: 0.13))
        /// 下行流量 / 回传
        static let downlink    = adaptive(hex(0x3B62D6), hex(0x7FA6FF))
        /// 上行流量的补充色
        static let uplink      = adaptive(hex(0x0C7D6E), hex(0x23C3AC))
        /// 需要留意
        static let caution     = adaptive(hex(0xD9911F), hex(0xE5A33C))
        static let cautionInk  = adaptive(hex(0x9A6417), hex(0xE5A33C))
        static let cautionWash = adaptive(hex(0xD9911F, alpha: 0.10), hex(0xE5A33C, alpha: 0.13))
        /// 危险 / 破坏性
        static let danger      = adaptive(hex(0xDB3B45), hex(0xF0525B))
        static let dangerInk   = adaptive(hex(0xC7363F), hex(0xF0525B))
        static let dangerWash  = adaptive(hex(0xDB3B45, alpha: 0.09), hex(0xF0525B, alpha: 0.13))

        // 填充
        static let fill          = adaptive(hex(0x141A22, alpha: 0.05), hex(0xFFFFFF, alpha: 0.06))
        static let fillStrong    = adaptive(hex(0x141A22, alpha: 0.085), hex(0xFFFFFF, alpha: 0.10))
        static let rowHover      = adaptive(hex(0x141A22, alpha: 0.035), hex(0xFFFFFF, alpha: 0.045))
        static let rowSelected   = adaptive(hex(0x12A88F, alpha: 0.085), hex(0x23C3AC, alpha: 0.12))

        // 图表
        static let chartGrid   = adaptive(hex(0x141A22, alpha: 0.07), hex(0xFFFFFF, alpha: 0.07))
    }

    // ------------------------------------------------------------------------
    // MARK: - 字体
    //  五级层级。所有数值使用等宽 tabular，刷新时宽度不跳动。
    // ------------------------------------------------------------------------

    /// 全局字号倍率，绑定设置里的"界面密度 / 字号"。
    static var scale: CGFloat = 1.0

    enum Typo {
        /// 大号读数，如 128 MB/s
        static func readout(_ s: CGFloat = scale) -> Font { .system(size: 19 * s, weight: .light) }
        /// 页面主标题
        static func title(_ s: CGFloat = scale) -> Font { .system(size: 17.5 * s, weight: .semibold) }
        /// 段落 / 弹窗标题
        static func heading(_ s: CGFloat = scale) -> Font { .system(size: 13 * s, weight: .semibold) }
        /// 正文
        static func body(_ s: CGFloat = scale) -> Font { .system(size: 12.5 * s) }
        /// 次级正文、表格内容
        static func dense(_ s: CGFloat = scale) -> Font { .system(size: 11.5 * s) }
        /// 说明文字、时间戳
        static func caption(_ s: CGFloat = scale) -> Font { .system(size: 11 * s) }
        /// 表头、微标签（配合大写字母与字距）
        static func micro(_ s: CGFloat = scale) -> Font { .system(size: 9.5 * s, weight: .semibold) }

        /// 等宽数字
        static func mono(_ size: CGFloat) -> Font {
            .system(size: size * scale, weight: .regular, design: .monospaced)
        }
        static func monoBold(_ size: CGFloat) -> Font {
            .system(size: size * scale, weight: .semibold, design: .monospaced)
        }
    }

    // ------------------------------------------------------------------------
    // MARK: - 尺寸
    // ------------------------------------------------------------------------

    enum Metrics {
        /// 间距基准 4，所有留白取自这条序列
        static let s1: CGFloat = 4
        static let s2: CGFloat = 8
        static let s3: CGFloat = 12
        static let s4: CGFloat = 16
        static let s5: CGFloat = 20
        static let s6: CGFloat = 24
        static let s8: CGFloat = 32

        /// 圆角
        static let rChip: CGFloat = 4
        static let rControl: CGFloat = 6
        static let rPanel: CGFloat = 9
        static let rWindow: CGFloat = 11
        static let rSheet: CGFloat = 12

        /// 控件高度
        static let hControl: CGFloat = 26
        static let hField: CGFloat = 28
        static let hRow: CGFloat = 34
        static let hRowCompact: CGFloat = 28
        static let hToolbar: CGFloat = 34

        /// 侧栏
        static let railWidth: CGFloat = 176
        /// 页面内边距
        static let pageInset: CGFloat = 20
    }
}

// ============================================================================
// MARK: - 基础修饰器
// ============================================================================

extension View {
    /// 发丝分隔线（水平）
    func hairlineTop() -> some View {
        overlay(alignment: .top) {
            Rectangle().fill(Lumen.Palette.hairlineSoft).frame(height: 1)
        }
    }

    func hairlineBottom() -> some View {
        overlay(alignment: .bottom) {
            Rectangle().fill(Lumen.Palette.hairlineSoft).frame(height: 1)
        }
    }

    /// 面板描边 + 圆角 + 浮起底色。全项目唯一的内容容器样式。
    func lumenPanel(radius: CGFloat = Lumen.Metrics.rPanel, fill: Color? = nil) -> some View {
        background(fill ?? Lumen.Palette.raised,
                   in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Lumen.Palette.hairline, lineWidth: 1))
    }

    /// 微标签：大写字母 + 字距，用于表头和小节标题
    func microLabel(_ color: Color = Lumen.Palette.textFaint) -> some View {
        font(Lumen.Typo.micro())
            .tracking(1.3)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

// ============================================================================
// MARK: - 文本
// ============================================================================

/// 微标签。表头、分组标题、字段名统一使用。
struct MicroText: View {
    let text: String
    var color: Color = Lumen.Palette.textFaint
    init(_ text: String, color: Color = Lumen.Palette.textFaint) {
        self.text = L10n.text(text)
        self.color = color
    }
    var body: some View {
        Text(self.text).microLabel(self.color)
    }
}

/// 等宽数字文本。所有读数、地址、端口、时长都走这里。
struct MonoText: View {
    let text: String
    var size: CGFloat = 11.5
    var weight: Font.Weight = .regular
    var color: Color = Lumen.Palette.text
    var body: some View {
        Text(text)
            .font(.system(size: size * Lumen.scale, weight: weight, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(color)
    }
}

/// 页面标题区块：模块编号 → 标题 → 一句话状态 → 右侧操作。
struct PageHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    let trailing: () -> Trailing

    init(title: String,
         eyebrow: String? = nil,
         subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.eyebrow = eyebrow
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let eyebrow {
                MicroText(eyebrow)
                    .padding(.bottom, Lumen.Metrics.s2)
            }
            HStack(alignment: .firstTextBaseline, spacing: Lumen.Metrics.s3) {
                Text(L10n.text(title))
                    .font(Lumen.Typo.title())
                    .foregroundStyle(Lumen.Palette.text)
                Spacer(minLength: Lumen.Metrics.s3)
                trailing()
            }
            if let subtitle {
                Text(L10n.text(subtitle))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .padding(.top, 5)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .padding(.top, 17)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension PageHeader where Trailing == EmptyView {
    /// 无右侧操作时的便捷构造。
    init(title: String, eyebrow: String? = nil, subtitle: String? = nil) {
        self.init(title: title, eyebrow: eyebrow, subtitle: subtitle) { EmptyView() }
    }
}

// ============================================================================
// MARK: - 按钮
// ============================================================================

enum LumenButtonKind {
    case primary, secondary, danger, plain
}

struct LumenButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var kind: LumenButtonKind = .secondary
    var icon: String?
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
            }
            configuration.label
                .font(.system(size: (compact ? 11 : 11.5) * Lumen.scale,
                              weight: kind == .primary ? .semibold : .regular))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, compact ? 9 : 11)
        .frame(height: compact ? 23 : Lumen.Metrics.hControl)
        .background(background, in: RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous)
            .strokeBorder(border, lineWidth: 1))
        .opacity(configuration.isPressed ? 0.72 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
    }

    private var foreground: Color {
        if !isEnabled { return Lumen.Palette.textFaint }
        switch kind {
        case .primary:   return .white
        case .secondary: return Lumen.Palette.text
        case .danger:    return Lumen.Palette.dangerInk
        case .plain:     return Lumen.Palette.textMuted
        }
    }

    private var background: Color {
        if !isEnabled { return Lumen.Palette.fill }
        switch kind {
        case .primary:   return Lumen.Palette.active
        case .secondary: return Lumen.Palette.raised
        case .danger:    return Lumen.Palette.dangerWash
        case .plain:     return .clear
        }
    }

    private var border: Color {
        if !isEnabled { return Lumen.Palette.hairline }
        switch kind {
        case .primary:   return .clear
        case .secondary: return Lumen.Palette.hairlineHard
        case .danger:    return Lumen.Palette.danger.opacity(0.32)
        case .plain:     return .clear
        }
    }
}

extension Button {
    func lumenButton(_ kind: LumenButtonKind = .secondary, icon: String? = nil, compact: Bool = false) -> some View {
        buttonStyle(LumenButtonStyle(kind: kind, icon: icon, compact: compact))
    }
}

/// 无边框图标按钮，用于工具栏和小标题右侧。
struct IconAction: View {
    let symbol: String
    var help: String
    var tint: Color = Lumen.Palette.textMuted
    var size: CGFloat = 13
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(hovering ? Lumen.Palette.text : tint)
                .frame(width: 24, height: 24)
                .background(hovering ? Lumen.Palette.fill : .clear,
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.text(help))
        .accessibilityLabel(L10n.text(help))
    }
}

// ============================================================================
// MARK: - 状态徽标
// ============================================================================

enum PillTone { case neutral, active, caution, danger }

struct Pill: View {
    let text: String
    var tone: PillTone = .neutral
    var symbol: String?

    init(_ text: String, tone: PillTone = .neutral, symbol: String? = nil) {
        self.text = L10n.text(text)
        self.tone = tone
        self.symbol = symbol
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 8.5, weight: .bold))
            }
            Text(text).font(.system(size: 10 * Lumen.scale, weight: .medium))
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 7)
        .frame(height: 19)
        .background(background, in: RoundedRectangle(cornerRadius: Lumen.Metrics.rChip, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rChip, style: .continuous)
            .strokeBorder(border, lineWidth: 1))
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .neutral: return Lumen.Palette.textMuted
        case .active:  return Lumen.Palette.activeInk
        case .caution: return Lumen.Palette.cautionInk
        case .danger:  return Lumen.Palette.dangerInk
        }
    }
    private var background: Color {
        switch tone {
        case .neutral: return Lumen.Palette.fill
        case .active:  return Lumen.Palette.activeWash
        case .caution: return Lumen.Palette.cautionWash
        case .danger:  return Lumen.Palette.dangerWash
        }
    }
    private var border: Color {
        switch tone {
        case .neutral: return Lumen.Palette.hairlineHard
        case .active:  return Lumen.Palette.active.opacity(0.28)
        case .caution: return Lumen.Palette.caution.opacity(0.28)
        case .danger:  return Lumen.Palette.danger.opacity(0.28)
        }
    }
}

/// 6px 状态圆点
struct StatusDot: View {
    var tone: PillTone = .active
    var size: CGFloat = 6
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(color.opacity(0.18), lineWidth: 3).padding(-1))
    }
    private var color: Color {
        switch tone {
        case .neutral: return Lumen.Palette.textFaint
        case .active:  return Lumen.Palette.active
        case .caution: return Lumen.Palette.caution
        case .danger:  return Lumen.Palette.danger
        }
    }
}

// ============================================================================
// MARK: - 读数
// ============================================================================

/// 字段读数：小写标签 + 等宽数值 + 单位。用于诊断、健康检查等面板。
struct Readout: View {
    let label: String
    let value: String
    var unit: String?
    var tone: Color = Lumen.Palette.text
    var valueSize: CGFloat = 13.5
    var labelWidth: CGFloat = 62

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Metrics.s2) {
            MicroText(label)
                .frame(width: labelWidth, alignment: .leading)
            MonoText(text: value, size: valueSize, color: tone)
            if let unit {
                Text(unit)
                    .font(.system(size: 10 * Lumen.scale))
                    .foregroundStyle(Lumen.Palette.textFaint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
    }
}

/// 进度条：细横条 + 数值。总览弹窗和阈值页使用。
struct MeterBar: View {
    var fraction: Double
    var tone: Color = Lumen.Palette.active
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Lumen.Palette.fillStrong)
                Capsule()
                    .fill(tone)
                    .frame(width: max(0, min(1, fraction)) * proxy.size.width)
            }
        }
        .frame(height: height)
    }
}

// ============================================================================
// MARK: - 面板
// ============================================================================

/// 带标题的面板。全项目唯一的内容容器：圆角 9、1px 描边、无阴影。
struct LumenPanel<Content: View>: View {
    let title: String?
    var code: String?
    var symbol: String?
    var trailing: AnyView?
    var padding: CGFloat
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil,
         code: String? = nil,
         symbol: String? = nil,
         trailing: AnyView? = nil,
         padding: CGFloat = 14,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.code = code
        self.symbol = symbol
        self.trailing = trailing
        self.padding = padding
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if title != nil || trailing != nil {
                HStack(spacing: Lumen.Metrics.s2) {
                    if title != nil {
                        Rectangle()
                            .fill(Lumen.Palette.active)
                            .frame(width: 3, height: 12)
                            .clipShape(RoundedRectangle(cornerRadius: 1.5))
                    }
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Lumen.Palette.textMuted)
                    }
                    if let title {
                        Text(L10n.text(title))
                            .font(Lumen.Typo.heading())
                            .foregroundStyle(Lumen.Palette.text)
                    }
                    if let code {
                        MonoText(text: code, size: 9, weight: .semibold, color: Lumen.Palette.textGhost)
                            .tracking(1.1)
                            .padding(.leading, 2)
                    }
                    Spacer(minLength: Lumen.Metrics.s2)
                    if let trailing { trailing }
                }
                .padding(.bottom, 11)
            }
            content()
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .lumenPanel()
    }
}

/// 分组小节标题，用于设置页与详情页。
struct SectionHeading: View {
    let title: String
    var body: some View {
        MicroText(title)
            .padding(.top, Lumen.Metrics.s5)
            .padding(.bottom, Lumen.Metrics.s2)
    }
}

// ============================================================================
// MARK: - 数据表格
//  统一表头 + 行。列宽用 ColumnSpec 描述，保证跨模块对齐一致。
// ============================================================================

struct ColumnSpec {
    enum Width {
        case fixed(CGFloat)
        case flexible(min: CGFloat, ideal: CGFloat)
    }
    let title: String
    let width: Width
    var alignment: Alignment = .leading
    /// 数值列右对齐并使用等宽字体
    var numeric = false

    static func fixed(_ title: String, _ w: CGFloat, alignment: Alignment = .leading, numeric: Bool = false) -> ColumnSpec {
        ColumnSpec(title: title, width: .fixed(w), alignment: alignment, numeric: numeric)
    }
    static func flex(_ title: String, min: CGFloat, ideal: CGFloat, alignment: Alignment = .leading, numeric: Bool = false) -> ColumnSpec {
        ColumnSpec(title: title, width: .flexible(min: min, ideal: ideal), alignment: alignment, numeric: numeric)
    }
}

/// 表头。与 GridRow 使用同一套列宽计算。
struct GridHeader: View {
    let columns: [ColumnSpec]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                Text(L10n.text(column.title))
                    .microLabel()
                    .frame(width: fixedWidth(column), alignment: column.alignment)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: isFlexible(column) ? .infinity : nil, alignment: column.alignment)
            }
        }
        .frame(height: 24)
        .hairlineBottom()
        .background(Lumen.Palette.canvas)
    }

    private func isFlexible(_ c: ColumnSpec) -> Bool {
        if case .flexible = c.width { return true }
        return false
    }
    private func fixedWidth(_ c: ColumnSpec) -> CGFloat? {
        if case .fixed(let w) = c.width { return w }
        return nil
    }
}

/// 表格行容器：负责悬停 / 选中底色、发丝下边线、点击。
struct GridRow<Content: View>: View {
    var selected = false
    var onTap: (() -> Void)?
    var onDoubleTap: (() -> Void)?
    var fixedHeight: CGFloat? = Lumen.Metrics.hRow
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .frame(height: fixedHeight)
            .background(background)
            .hairlineBottom()
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(count: 2) { onDoubleTap?() }
            .onTapGesture { onTap?() }
    }

    private var background: Color {
        if selected { return Lumen.Palette.rowSelected }
        if hovering { return Lumen.Palette.rowHover }
        return .clear
    }
}

// ============================================================================
// MARK: - 输入控件
// ============================================================================

/// 带放大镜的搜索框。
struct SearchBox: View {
    let placeholder: String
    @Binding var text: String
    var width: CGFloat = 210

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Lumen.Palette.textFaint)
            TextField(L10n.text(placeholder), text: $text)
                .textFieldStyle(.plain)
                .font(Lumen.Typo.dense())
                .foregroundStyle(Lumen.Palette.text)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Lumen.Palette.textFaint)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: Lumen.Metrics.hField)
        .background(Lumen.Palette.raised, in: RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous)
            .strokeBorder(Lumen.Palette.hairlineHard, lineWidth: 1))
    }
}

/// 分段控件。用于筛选与模式切换。
struct SegmentedBar<T: Hashable>: View {
    let options: [(String, T)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                let on = option.1 == selection
                Button { selection = option.1 } label: {
                    Text(L10n.text(option.0))
                        .font(.system(size: 11.5 * Lumen.scale, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Lumen.Palette.activeInk : Lumen.Palette.textMuted)
                        .padding(.horizontal, 11)
                        .frame(height: Lumen.Metrics.hField - 2)
                        .background(on ? Lumen.Palette.activeWash : .clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if index < options.count - 1 {
                    Rectangle().fill(Lumen.Palette.hairline).frame(width: 1)
                }
            }
        }
        .frame(height: Lumen.Metrics.hField)
        .background(Lumen.Palette.raised, in: RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous)
            .strokeBorder(Lumen.Palette.hairlineHard, lineWidth: 1))
    }
}

/// 开关
struct LumenToggle: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .tint(Lumen.Palette.active)
    }
}

/// 数字输入框，用于阈值设置。
struct NumberField: View {
    @Binding var value: Double
    var width: CGFloat = 58
    var unit: String?

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: $value, format: .number.precision(.fractionLength(0...1)))
                .textFieldStyle(.plain)
                .font(Lumen.Typo.mono(11.5))
                .multilineTextAlignment(.trailing)
                .frame(width: width)
                .padding(.horizontal, 7)
                .frame(height: 25)
                .background(Lumen.Palette.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Lumen.Palette.hairlineHard, lineWidth: 1))
            if let unit {
                Text(L10n.text(unit))
                    .font(.system(size: 10.5 * Lumen.scale))
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .frame(width: 34, alignment: .leading)
            }
        }
    }
}

// ============================================================================
// MARK: - 空态
// ============================================================================

struct EmptyState: View {
    let symbol: String
    let title: String
    var detail: String?
    var action: (label: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: Lumen.Metrics.s3) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Lumen.Palette.textGhost)
            Text(L10n.text(title))
                .font(Lumen.Typo.heading())
                .foregroundStyle(Lumen.Palette.textMuted)
            if let detail {
                Text(L10n.text(detail))
                    .font(Lumen.Typo.caption())
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 330)
            }
            if let action {
                Button(L10n.text(action.label), action: action.run)
                    .lumenButton(.secondary, compact: true)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Lumen.Metrics.s8)
    }
}

// ============================================================================
// MARK: - 图表
// ============================================================================

/// 双色流量折线。青色为下行，蓝色为上行；间隙自动断开。
struct TrafficSparkline: View {
    let samples: [Double]
    let secondary: [Double]?
    var fill = true

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                // 基线网格
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { i in
                        Rectangle()
                            .fill(Lumen.Palette.chartGrid)
                            .frame(height: 1)
                        if i < 2 { Spacer(minLength: 0) }
                    }
                }
                let primary = path(for: samples, in: size)
                if fill, let primary {
                    primary
                        .toShape()
                        .fill(LinearGradient(colors: [Lumen.Palette.active.opacity(0.18), Lumen.Palette.active.opacity(0.01)],
                                             startPoint: .top, endPoint: .bottom))
                }
                if let primary {
                    primary.stroke(Lumen.Palette.active,
                                   style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                if let secondary, let p2 = path(for: secondary, in: size) {
                    p2.stroke(Lumen.Palette.downlink.opacity(0.8),
                              style: StrokeStyle(lineWidth: 1.1, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }

    /// 归一化并生成折线路径（保留原始采样顺序，不做平滑，读数才诚实）
    private func path(for values: [Double], in size: CGSize) -> Path? {
        guard values.count > 1 else { return nil }
        let maxValue = max(values.max() ?? 1, 0.0001)
        let stepX = size.width / CGFloat(values.count - 1)
        var path = Path()
        for (index, value) in values.enumerated() {
            let x = CGFloat(index) * stepX
            let y = size.height - CGFloat(min(1, max(0, value / maxValue))) * (size.height - 4) - 2
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }
}

private extension Path {
    /// 把折线闭合成可填充区域：下沿延伸到视图底部之外，避免出现折角。
    func toShape() -> Path {
        var copy = self
        let bounds = copy.boundingRect
        copy.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY + 400))
        copy.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY + 400))
        copy.closeSubpath()
        return copy
    }
}

/// 圆弧仪表。诊断页的吞吐、进度类读数使用。
struct GaugeDial: View {
    let value: Double
    let maxValue: Double
    let caption: String
    let display: String
    var size: CGFloat = 78
    var tint: Color = Lumen.Palette.active

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.125, to: 0.875)
                .stroke(Lumen.Palette.fillStrong, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.125, to: 0.125 + 0.75 * fraction)
                .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(90))
            VStack(spacing: 1) {
                MonoText(text: display, size: 17, weight: .light, color: Lumen.Palette.text)
                Text(L10n.text(caption).uppercased())
                    .font(.system(size: 8 * Lumen.scale, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Lumen.Palette.textGhost)
            }
        }
        .frame(width: size, height: size)
    }

    private var fraction: Double {
        guard maxValue > 0 else { return 0 }
        return min(1, max(0, value / maxValue))
    }
}

// ============================================================================
// MARK: - 键值行
// ============================================================================

/// 设置项行：标题 + 说明 + 右侧控件。
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: Lumen.Metrics.s4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.text(title))
                    .font(Lumen.Typo.body())
                    .foregroundStyle(Lumen.Palette.text)
                if let detail {
                    Text(L10n.text(detail))
                        .font(Lumen.Typo.caption())
                        .foregroundStyle(Lumen.Palette.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Lumen.Metrics.s4)
            control()
        }
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .hairlineBottom()
    }
}

/// 详情页的键值对
struct DetailPair: View {
    let key: String
    let value: String
    var mono = false
    var labelWidth: CGFloat = 96

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Lumen.Metrics.s3) {
            MicroText(key).frame(width: labelWidth, alignment: .leading)
            if mono {
                MonoText(text: value, size: 11.5).textSelection(.enabled)
            } else {
                Text(value)
                    .font(Lumen.Typo.dense())
                    .foregroundStyle(Lumen.Palette.text)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}

// ============================================================================
// MARK: - 提示条
// ============================================================================

struct NoticeBar: View {
    enum Level { case info, caution, danger }
    let level: Level
    let text: String
    var symbol: String?

    var body: some View {
        HStack(alignment: .top, spacing: Lumen.Metrics.s2) {
            Image(systemName: symbol ?? defaultSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(L10n.text(text))
                .font(Lumen.Typo.caption())
                .foregroundStyle(Lumen.Palette.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(wash, in: RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Lumen.Metrics.rControl, style: .continuous)
            .strokeBorder(tint.opacity(0.22), lineWidth: 1))
    }

    private var tint: Color {
        switch level {
        case .info:    return Lumen.Palette.textFaint
        case .caution: return Lumen.Palette.caution
        case .danger:  return Lumen.Palette.danger
        }
    }
    private var wash: Color {
        switch level {
        case .info:    return Lumen.Palette.fill
        case .caution: return Lumen.Palette.cautionWash
        case .danger:  return Lumen.Palette.dangerWash
        }
    }
    private var defaultSymbol: String {
        switch level {
        case .info:    return "info.circle"
        case .caution: return "exclamationmark.triangle"
        case .danger:  return "exclamationmark.octagon"
        }
    }
}

// ============================================================================
// MARK: - 页脚状态条
// ============================================================================

struct PageFooter: View {
    let leading: String?
    var tone: PillTone = .neutral
    let trailing: [String]

    init(leading: String? = nil, tone: PillTone = .neutral, trailing: [String] = []) {
        self.leading = leading
        self.tone = tone
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: Lumen.Metrics.s3) {
            if leading != nil { StatusDot(tone: tone, size: 5) }
            if let leading {
                Text(L10n.text(leading))
                    .font(.system(size: 10.5 * Lumen.scale))
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: Lumen.Metrics.s3)
            ForEach(Array(trailing.enumerated()), id: \.offset) { _, item in
                Text(L10n.text(item))
                    .font(.system(size: 10.5 * Lumen.scale))
                    .foregroundStyle(Lumen.Palette.textFaint)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, Lumen.Metrics.pageInset)
        .frame(height: 30)
        .background(Lumen.Palette.rail)
        .hairlineTop()
    }
}

// ============================================================================
// MARK: - 应用图标字形
// ============================================================================

/// 无图标应用时的首字母字形，避免空白与默认图标噪音。
struct AppGlyph: View {
    let name: String
    var image: NSImage?
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(initials)
                    .font(.system(size: size * 0.46, weight: .bold, design: .rounded))
                    .foregroundStyle(Lumen.Palette.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Lumen.Palette.fillStrong)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
            .strokeBorder(Lumen.Palette.hairline, lineWidth: 0.5))
    }

    private var initials: String {
        let letters = name.prefix(2)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}

// ============================================================================
// MARK: - 滚动容器
// ============================================================================

/// 统一滚动样式：隐藏系统背景、只在需要时出现滚动条。
struct LumenScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            content()
        }
        .scrollContentBackground(.hidden)
        .background(Lumen.Palette.canvas)
    }
}

// ============================================================================
// MARK: - 文案格式化
// ============================================================================

enum UnitFormat {
    /// 字节 → 人类可读（1024 进制，保留 1 位小数）
    static func bytes(_ value: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB"]
        var amount = Double(value)
        var index = 0
        while amount >= 1024, index < units.count - 1 {
            amount /= 1024
            index += 1
        }
        if index == 0 { return String(format: "%.0f %@", amount, units[index]) }
        return String(format: amount >= 100 ? "%.0f %@" : "%.1f %@", amount, units[index])
    }

    /// 速率 → KB/s 或 MB/s
    static func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1024 * 1024 {
            return String(format: "%.1f MB/s", bytesPerSecond / 1024 / 1024)
        }
        if bytesPerSecond >= 1024 {
            return String(format: "%.0f KB/s", bytesPerSecond / 1024)
        }
        return String(format: "%.0f B/s", bytesPerSecond)
    }

    /// 速率拆成数值与单位，便于分别排版
    static func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        if bytesPerSecond >= 1024 * 1024 {
            return (String(format: "%.1f", bytesPerSecond / 1024 / 1024), "MB/s")
        }
        if bytesPerSecond >= 1024 {
            return (String(format: "%.0f", bytesPerSecond / 1024), "KB/s")
        }
        return (String(format: "%.0f", bytesPerSecond), "B/s")
    }

    /// 按当前语言给出省略号分隔的说明句
    static func joined(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
