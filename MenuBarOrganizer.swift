import AppKit
import SwiftUI

/// Independently implemented: an invisible spacer hides items while the arrow stays fixed-width.
final class MenuBarOrganizer: NSObject, ObservableObject {
    static let shared = MenuBarOrganizer()
    @Published private(set) var enabled: Bool
    @Published private(set) var expanded = true
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private var arrow: NSStatusItem?
    private var spacer: NSStatusItem?
    private var spacerPreferredPosition: Double?
    private weak var residentItem: NSStatusItem?
    private var restoreResident: ((Double) -> NSStatusItem?)?

    func keepResident(_ item: NSStatusItem, restore: @escaping (Double) -> NSStatusItem?) {
        residentItem = item
        restoreResident = restore
    }

    private func restoreResidentIfNeeded() {
        guard let residentFrame = residentItem?.button?.window?.frame,
              let controlFrame = arrow?.button?.window?.frame,
              residentFrame.minX < controlFrame.maxX - 1 else { return }
        let position = UserDefaults.standard.double(forKey: "NSStatusItem Preferred Position AILock.Organizer.Control")
        residentItem = restoreResident?(max(0, position - 1)) ?? residentItem
    }
    var controlLength: CGFloat? { arrow?.length }
    var hiddenSpaceLength: CGFloat? { spacer?.length }
    private var hideTimer: Timer?
    private var screenObserver: NSObjectProtocol?
    private var preferenceObserver: NSObjectProtocol?
    private var languageObserver: NSObjectProtocol?
    private var layoutRequest = UUID()
    private var hiddenWindowIDs: Set<CGWindowID> = []
    private var expansionPending = false
    static var supportsFolding: Bool { ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27 }
    static let enabledKey = "menubar.organizer.enabled"
    static let autoHideKey = "menubar.organizer.autoHide"
    static let settingsChanged = Notification.Name("AILock.menuBarOrganizerSettingsChanged")

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey) && Self.supportsFolding
        super.init()
        defaults.register(defaults: [Self.autoHideKey: true])
    }

    func toggleEnabled() {
        defaults.set(!enabled && Self.supportsFolding, forKey: Self.enabledKey)
        applyPreferences()
    }

    static func collapsedLength(screenWidths: [CGFloat]) -> CGFloat {
        // Preferred positions are ordering hints and can include an old folded
        // spacer's width. Size from display geometry, not those saved values.
        max(500, min(max((screenWidths.max() ?? 500) * 2, screenWidths.reduce(0, +)), 10_000))
    }

    /// Larger preferred positions are left of the arrow, in the collection area.
    static func spacerPosition(after arrowPosition: Double, occupiedPositions: [Double]) -> Double {
        let epsilon = 0.000_001
        guard let nearestItem = occupiedPositions.filter({ $0 > arrowPosition + epsilon }).min() else {
            return arrowPosition + 1
        }
        // Never select the resident icon to the right, even if it is closer.
        var candidate = (arrowPosition + nearestItem) / 2
        while occupiedPositions.contains(where: { abs($0 - candidate) < epsilon }) {
            candidate = (arrowPosition + candidate) / 2
            if abs(candidate - arrowPosition) < epsilon {
                return arrowPosition + epsilon * 2
            }
        }
        return candidate
    }

    private func statusItemPositions() -> [Double] {
        let prefix = "NSStatusItem Preferred Position "
        // Third-party menu-bar apps store positions in their own defaults
        // suites. Inspect running app suites as well as Apple's menu-bar suites.
        let suiteNames = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let domains = suiteNames.compactMap { UserDefaults(suiteName: $0)?.dictionaryRepresentation() }
            + [UserDefaults.standard.dictionaryRepresentation(),
               UserDefaults(suiteName: "com.apple.controlcenter")?.dictionaryRepresentation() ?? [:],
               UserDefaults(suiteName: "com.apple.systemuiserver")?.dictionaryRepresentation() ?? [:]]
        return domains.flatMap { domain in
            domain.compactMap { key, value -> Double? in
                guard key.hasPrefix(prefix), key != prefix + "AILock.Organizer.Space" else { return nil }
                return (value as? NSNumber)?.doubleValue
            }
        }
    }

    private func nextSpacerPosition(occupiedPositions: [Double]) -> Double {
        let prefix = "NSStatusItem Preferred Position "
        let arrowPosition = UserDefaults.standard.double(forKey: prefix + "AILock.Organizer.Control")
        return Self.spacerPosition(after: arrowPosition, occupiedPositions: occupiedPositions)
    }

    func start() {
        guard preferenceObserver == nil else { return }
        preferenceObserver = NotificationCenter.default.addObserver(forName: Self.settingsChanged, object: nil, queue: .main) { [weak self] _ in self?.applyPreferences() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.applyLayout() }
        languageObserver = NotificationCenter.default.addObserver(forName: L10n.changed, object: nil, queue: .main) { [weak self] _ in self?.updateArrow() }
        applyPreferences()
    }

    private func applyPreferences() {
        enabled = defaults.bool(forKey: Self.enabledKey) && Self.supportsFolding
        if enabled {
            if arrow == nil {
                let key = "NSStatusItem Preferred Position AILock.Organizer.Control"
                if UserDefaults.standard.object(forKey: key) == nil { UserDefaults.standard.set(300, forKey: key) }
                let control = NSStatusBar.system.statusItem(withLength: 24)
                control.autosaveName = "AILock.Organizer.Control"
                control.button?.target = self; control.button?.action = #selector(arrowClicked(_:))
                control.button?.sendAction(on: [.leftMouseUp])
                arrow = control
                // A separate, unlabelled item absorbs the width. Resizing the
                // visible arrow itself makes macOS evict it from the menu bar.
                expanded = true // Initially allow the user to arrange icons around the arrow.
            }
            applyLayout()
            scheduleAutoHide()
        } else {
            removeItems()
        }
    }

    private func applyLayout(repositionSpacer: Bool = false) {
        arrow?.length = 24
        // Only reposition the resident item before folding it. During expansion,
        // rebuilding its NSStatusItem makes the icon blink as hidden items return.
        if !expanded { restoreResidentIfNeeded() }
        if expanded {
            // isVisible=false clears the native saved position. Reusing that
            // item on the next fold can put it on the wrong side of the arrow.
            // Remove once, without first resizing, to avoid two layout passes.
            if let spacer { NSStatusBar.system.removeStatusItem(spacer) }
            spacer = nil
            spacerPreferredPosition = nil
        } else {
            // Command-dragging a new icon immediately left of the arrow can
            // put it between the arrow and the invisible spacer. Reinsert the
            // spacer at the arrow boundary so it includes those new icons.
            if arrow?.button?.window != nil, spacer == nil || repositionSpacer {
                // Place the spacer immediately on the arrow-facing side of the
                // nearest collected icon, even if a system extra uses arrow+1.
                let occupiedPositions = statusItemPositions()
                let position = nextSpacerPosition(occupiedPositions: occupiedPositions)
                if spacer == nil || spacerPreferredPosition.map({ abs($0 - position) > 0.000_001 }) ?? true {
                    spacer?.length = 1
                    if let spacer { NSStatusBar.system.removeStatusItem(spacer) }
                    UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position AILock.Organizer.Space")
                    let replacement = NSStatusBar.system.statusItem(withLength: 1)
                    replacement.autosaveName = "AILock.Organizer.Space"
                    spacer = replacement
                    spacerPreferredPosition = position
                }
            }
            spacer?.length = Self.collapsedLength(screenWidths: NSScreen.screens.map { $0.frame.width })
        }
        layoutRequest = UUID()
        expansionPending = expanded && !hiddenWindowIDs.isEmpty
        if expanded, !hiddenWindowIDs.isEmpty {
            arrow?.button?.toolTip = L10n.text("正在展开菜单栏图标…")
            updateExpandedArrowWhenVisible(request: layoutRequest, deadline: Date().addingTimeInterval(2))
        } else {
            updateArrow()
        }
        if !expanded {
            let request = layoutRequest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self, self.layoutRequest == request, self.enabled, !self.expanded else { return }
                if ProcessInfo.processInfo.environment["AILOCK_MENUBAR_TRACE"] == "1" {
                    NSLog("Menu bar fold: arrow=%@ resident=%@ screens=%@", String(describing: self.arrow?.button?.window?.frame), String(describing: self.residentItem?.button?.window?.frame), String(describing: NSScreen.screens.map(\.frame)))
                }
                guard let frame = self.arrow?.button?.window?.frame,
                      NSScreen.screens.contains(where: { $0.frame.intersects(frame) }),
                      self.residentItem.map({ item in
                          guard let residentFrame = item.button?.window?.frame else { return false }
                          return residentFrame.minX >= frame.maxX - 1 && NSScreen.screens.contains { $0.frame.intersects(residentFrame) }
                      }) ?? true else {
                    self.expanded = true
                    self.hideTimer?.invalidate(); self.hideTimer = nil
                    self.applyLayout()
                    self.message = "系统未能保留收纳箭头，已自动恢复展开。"
                    return
                }
            }
        }
    }

    private func updateArrow() {
        arrow?.button?.image = NSImage(systemSymbolName: expanded ? "chevron.right" : "chevron.left", accessibilityDescription: expanded ? L10n.text("收起菜单栏图标") : L10n.text("展开菜单栏图标"))
        arrow?.button?.toolTip = L10n.text("> 左侧为收纳区；收起后显示 <，点击展开。")
        arrow?.button?.setAccessibilityLabel(expanded ? L10n.text("收起菜单栏图标") : L10n.text("展开菜单栏图标"))
    }

    // Window metadata only: no screenshots, titles, or screen-recording prompt.
    private func visibleWindowFrames() -> [CGWindowID: CGRect] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var frames: [CGWindowID: CGRect] = [:]
        for window in windows {
            guard let id = window[kCGWindowNumber as String] as? UInt32,
                  let layer = window[kCGWindowLayer as String] as? Int, (24...30).contains(layer),
                  let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds), frame.height <= 60, frame.width < 500 else { continue }
            frames[id] = frame
        }
        return frames
    }

    private func rememberVisibleIcons() {
        guard let controlFrame = arrow?.button?.window?.frame else { return }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        hiddenWindowIDs = Set(visibleWindowFrames().compactMap { id, frame in
            let converted = CGRect(x: frame.minX, y: top - frame.maxY, width: frame.width, height: frame.height)
            return converted.maxX <= controlFrame.minX + 1 && abs(converted.midY - controlFrame.midY) < 20 ? id : nil
        })
    }

    private func updateExpandedArrowWhenVisible(request: UUID, deadline: Date) {
        guard layoutRequest == request, expanded, enabled else { return }
        let visible = Set(visibleWindowFrames().keys)
        if hiddenWindowIDs.isSubset(of: visible) || Date() >= deadline {
            hiddenWindowIDs = []
            expansionPending = false
            updateArrow()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.updateExpandedArrowWhenVisible(request: request, deadline: deadline)
            }
        }
    }

    @objc private func arrowClicked(_ sender: Any?) {
        // The native menu bar completes its layout asynchronously. Do not
        // reverse an expansion before the hidden icons have returned.
        guard !expansionPending else { return }
        toggle()
    }

    func toggle() {
        guard enabled else { return }
        if expanded { rememberVisibleIcons() }
        expanded.toggle(); applyLayout(repositionSpacer: !expanded); scheduleAutoHide()
    }

    func expandForArrangement() {
        guard enabled else { return }
        hideTimer?.invalidate(); hideTimer = nil
        expanded = true; applyLayout()
    }

    private func scheduleAutoHide() {
        hideTimer?.invalidate(); hideTimer = nil
        guard enabled, expanded, defaults.bool(forKey: Self.autoHideKey) else { return }
        let timer = Timer(timeInterval: 15, repeats: false) { [weak self] _ in
            guard let self, self.enabled, self.expanded else { return }
            let pointer = NSEvent.mouseLocation
            // Keep visible while arranging or interacting near the menu bar.
            let interacting = NSScreen.screens.contains { screen in
                pointer.x >= screen.frame.minX && pointer.x <= screen.frame.maxX && pointer.y >= screen.visibleFrame.maxY && pointer.y <= screen.frame.maxY
            }
            if interacting { self.scheduleAutoHide() }
            else { self.rememberVisibleIcons(); self.expanded = false; self.applyLayout(repositionSpacer: true) }
        }
        hideTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func removeItems() {
        layoutRequest = UUID(); hiddenWindowIDs = []; expansionPending = false
        hideTimer?.invalidate(); hideTimer = nil
        spacer?.length = 1 // Restore hidden items before removing our control.
        if let spacer { NSStatusBar.system.removeStatusItem(spacer) }
        if let arrow { NSStatusBar.system.removeStatusItem(arrow) }
        spacer = nil; spacerPreferredPosition = nil; arrow = nil; expanded = true
    }

    func stop() {
        removeItems()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let preferenceObserver { NotificationCenter.default.removeObserver(preferenceObserver) }
        if let languageObserver { NotificationCenter.default.removeObserver(languageObserver) }
        screenObserver = nil; preferenceObserver = nil; languageObserver = nil
    }
}

struct MenuBarOrganizerSettingsView: View {
    @AppStorage(MenuBarOrganizer.enabledKey) private var enabled = false
    @AppStorage(MenuBarOrganizer.autoHideKey) private var autoHide = true
    @AppStorage("overview.language") private var localizationEnglish = false
    @AppStorage("overview.followSystemLanguage") private var localizationFollowsSystem = true
    var body: some View {
        let _ = localizationEnglish
        let _ = localizationFollowsSystem
        VStack(alignment: .leading, spacing: 16) {
            Text(L10n.text("菜单栏收纳")).font(.title2)
            Text(L10n.text("在首页点击菜单栏收纳图标开启或关闭，绿色小点表示已开启。"))
                .font(.callout).foregroundStyle(.secondary)
            if !MenuBarOrganizer.supportsFolding {
                Text(L10n.text("当前系统的菜单栏布局暂不支持折叠。"))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Text(L10n.text("按住 ⌘ 把不常用图标拖到 > 左侧，常用图标和 AI Lock 留在右侧。默认离开菜单栏 15 秒后自动收起，箭头变成 <；点击 < 展开，恢复 >。"))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle(L10n.text("展开 15 秒后自动收起"), isOn: $autoHide).disabled(!enabled)
            HStack {
                Button(L10n.text("展开并整理图标")) { MenuBarOrganizer.shared.expandForArrangement() }.disabled(!enabled)
            }
        }
        .onChange(of: autoHide) { _, _ in changed() }
    }
    private func changed() { NotificationCenter.default.post(name: MenuBarOrganizer.settingsChanged, object: nil) }
}

