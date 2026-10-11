import AppKit
import SwiftUI

let ink = NSColor.labelColor
let muted = NSColor.secondaryLabelColor
let canvas = NSColor.windowBackgroundColor
let cardColor = NSColor.controlBackgroundColor
let lime = NSColor(calibratedRed: 0.71, green: 0.96, blue: 0.35, alpha: 1)
let panelColor = NSColor.clear

class ModuleViewController: NSViewController {
    func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = ink, mono: Bool = false) -> NSTextField {
        let result = LocalizedLabel(labelWithString: L10n.text(text))
        let size = min(size, 12)
        result.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        result.textColor = color; result.translatesAutoresizingMaskIntoConstraints = false
        return result
    }
    func toolbarButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = DelayedHelpButton(title: L10n.text(title), target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.text(title))
        button.imagePosition = .imageLeading; button.bezelStyle = .rounded
        return button
    }
    func presentMessage(_ title: String, detail: String) {
        let alert = NSAlert(); alert.messageText = L10n.text(title); alert.informativeText = L10n.text(detail)
        if let window = view.window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// A shared nonactivating panel keeps explanations outside clipped grids and popovers.
final class DelayedIconHelp {
    static let shared = DelayedIconHelp()
    static let delay: TimeInterval = 2
    private var owner: UUID?
    private var pending: DispatchWorkItem?
    private var panel: NSPanel?
    private var closeObserver: NSObjectProtocol?
    var isVisible: Bool { panel?.isVisible == true }

    func begin(_ sourceText: String, owner: UUID, window: NSWindow? = nil) {
        let text = L10n.text(sourceText)
        hide()
        guard !text.isEmpty else { return }
        self.owner = owner
        let point = NSEvent.mouseLocation
        let source = window ?? NSApp.windows.first { $0.isVisible && $0.frame.contains(point) && $0 !== panel }
        guard let source else { return }
        let work = DispatchWorkItem { [weak self, weak source] in
            guard let self, self.owner == owner, let source, source.isVisible else { return }
            self.show(text, near: NSEvent.mouseLocation, source: source)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: source, queue: .main) { [weak self] _ in self?.end(owner: owner) }
    }

    func end(owner: UUID) {
        guard self.owner == owner else { return }
        hide()
    }

    func hide() {
        pending?.cancel(); pending = nil
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        owner = nil
        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
    }

    private func show(_ text: String, near point: NSPoint, source: NSWindow) {
        let panel = self.panel ?? NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        self.panel = panel
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = source.appearance
        let label = LocalizedLabel(wrappingLabelWithString: L10n.text(text))
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.setAccessibilityRole(.helpTag)
        let width = min(280, max(100, (text as NSString).size(withAttributes: [.font: label.font!]).width))
        let height = ceil((text as NSString).boundingRect(with: NSSize(width: width, height: 1000), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: label.font!]).height)
        let size = NSSize(width: width + 20, height: height + 16)
        let background = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        background.material = .popover
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        label.frame = NSRect(x: 10, y: 8, width: width, height: height)
        background.addSubview(label)
        panel.contentView = background
        let screen = NSScreen.screens.first { $0.frame.contains(point) }?.visibleFrame ?? source.screen?.visibleFrame ?? source.frame
        let x = min(max(screen.minX + 4, point.x + 12), screen.maxX - size.width - 4)
        let y = max(screen.minY + 4, min(point.y - size.height - 12, screen.maxY - size.height - 4))
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        source.addChildWindow(panel, ordered: .above)
        panel.orderFrontRegardless()
    }
}

private struct DelayedHelpModifier: ViewModifier {
    let text: String
    @State private var owner = UUID()
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering { DelayedIconHelp.shared.begin(text, owner: owner) }
                else { DelayedIconHelp.shared.end(owner: owner) }
            }
            .simultaneousGesture(TapGesture().onEnded { DelayedIconHelp.shared.end(owner: owner) })
            .onDisappear { DelayedIconHelp.shared.end(owner: owner) }
            .accessibilityHint(L10n.text(text))
    }
}

extension View {
    func delayedHelp(_ text: String) -> some View { modifier(DelayedHelpModifier(text: text)) }
}

final class DelayedHelpButton: LocalizedButton {
    private let helpOwner = UUID()
    private var helpTrackingArea: NSTrackingArea?
    var helpDescription: String?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let helpTrackingArea { removeTrackingArea(helpTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        helpTrackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        DelayedIconHelp.shared.begin(helpDescription ?? IconHelp.description(for: title), owner: helpOwner, window: window)
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        DelayedIconHelp.shared.end(owner: helpOwner)
    }
    override func mouseDown(with event: NSEvent) {
        DelayedIconHelp.shared.end(owner: helpOwner)
        super.mouseDown(with: event)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { DelayedIconHelp.shared.end(owner: helpOwner) }
    }
}

enum IconHelp {
    static func description(for title: String) -> String {
        [
            "通用": "设置语言、外观、字号、菜单栏指标和开机自启动。",
            "系统扩展": "查看和配置连接过滤、文件审计扩展。",
            "监控预警": "调整资源预警阈值，异常时在菜单栏显示提示。",
            "DockLock": "设置程序坞锁定的显示器和自动拉回行为。",
            "首页图标": "选择在总览显示的功能图标。",
            "快捷键": "双击 Command 打开快捷操作条。",
            "帮助/关于": "查看使用说明、版本信息和版权。",
            "打开": "打开所选应用或文件。",
            "保存阈值": "保存预警阈值，下一次采样时生效。",
            "测试预警": "让菜单栏指标显示白字红底预警标记 5 秒。",
            "监控目录": "选择目录并持续记录该目录的文件活动。",
            "停止监控": "停止当前目录的文件活动监控。",
            "取消扫描": "停止正在进行的文件分析。",
            "分析文件": "扫描所选目录，统计文件大小和类型。",
            "退出用户应用…": "选择并请求退出用户应用，操作前会确认。",
            "确认清理所列缓存…": "预览并确认清理当前列表中的用户缓存。",
            "清理所选缓存…": "预览并确认清理所选缓存。",
            "开始检查": "扫描用户缓存并展示可清理的项目。",
            "卸载所选应用…": "预览应用及可识别残留，确认后卸载。",
            "刷新": "重新读取应用列表。",
            "重新扫描": "重新检查本机启动项。",
            "系统登录项设置": "打开 macOS 登录项与后台项目设置。",
            "清空历史": "清空剪贴板历史记录。",
            "排除应用": "选择不采集剪贴板内容的应用。",
            "复制所选": "将选中的历史记录复制回剪贴板。",
            "加载更多": "加载下一页剪贴板历史记录。"
        ][L10n.original(title)] ?? title
    }
}

/// Native labels keep the source text so cached windows can switch language without
/// rebuilding controllers, losing selections or restarting monitoring.
final class LocalizedLabel: NSTextField {
    private var sourceText = ""
    override var stringValue: String {
        get { super.stringValue }
        set { sourceText = L10n.original(newValue); super.stringValue = L10n.text(sourceText) }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: L10n.changed, object: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc private func languageChanged() { super.stringValue = L10n.text(sourceText) }
    deinit { NotificationCenter.default.removeObserver(self) }
}

class LocalizedButton: NSButton {
    private var sourceTitle = ""
    override var title: String {
        get { super.title }
        set { sourceTitle = L10n.original(newValue); super.title = L10n.text(sourceTitle) }
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(languageChanged), name: L10n.changed, object: nil)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    @objc private func languageChanged() {
        super.title = L10n.text(sourceTitle)
        if let description = image?.accessibilityDescription { image?.accessibilityDescription = L10n.text(L10n.original(description)) }
        toolTip = toolTip.map { L10n.text(L10n.original($0)) }
    }
    deinit { NotificationCenter.default.removeObserver(self) }
}

enum NativeLocalization {
    static func refresh(_ window: NSWindow) {
        window.title = L10n.text(L10n.original(window.title))
        if let content = window.contentView { refresh(content) }
    }
    private static func refresh(_ menu: NSMenu) {
        for item in menu.items {
            item.title = L10n.text(L10n.original(item.title))
            if let submenu = item.submenu { refresh(submenu) }
        }
    }
    private static func refresh(_ view: NSView) {
        if let search = view as? NSSearchField {
            search.placeholderString = search.placeholderString.map { L10n.text(L10n.original($0)) }
        }
        if let popup = view as? NSPopUpButton {
            for item in popup.itemArray { item.title = L10n.text(L10n.original(item.title)) }
        }
        if let segmented = view as? NSSegmentedControl {
            for index in 0..<segmented.segmentCount {
                if let title = segmented.label(forSegment: index) { segmented.setLabel(L10n.text(L10n.original(title)), forSegment: index) }
            }
        }
        if let table = view as? NSTableView {
            for column in table.tableColumns { column.title = L10n.text(L10n.original(column.title)) }
            if let menu = table.menu { refresh(menu) }
            table.reloadData()
        }
        view.subviews.forEach(refresh)
    }
}
