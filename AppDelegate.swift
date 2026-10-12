import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
    private let statusMetricIconSize: CGFloat = 18
    private let statusMetricFontSize: CGFloat = 14
    private let lock = DockLock()
    private var item: NSStatusItem!
    private var baseStatusToolTip = ""
    private var networkToolTipIsVisible = false
    private var settingsMenu: NSMenu!
    private var dockLockItem: NSMenuItem?
    private var screenMenu: NSMenu!
    private var screenItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var waitTimer: Timer?
    private let overviewPopover = NSPopover()
    private var overviewLocalClickMonitor: Any?
    private var overviewGlobalClickMonitor: Any?
    private let monitoring = MonitoringService.shared
    private let statusAlerts = ResourceAlerts()
    private var alertBlinkTimer: Timer?
    private var alertBlinkBright = true
    private var alertPreviewUntil = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        DashboardWindow.setDockLockController(lock)
        DashboardWindow.onWillShowFunctionalWindow = { [weak self] in
            self?.overviewPopover.close()
        }
        NotificationManager.shared.start()
        setupStatusItem()
        MenuBarOrganizer.shared.keepResident(item) { [weak self] position in
            guard let self else { return nil }
            if let old = self.item { NSStatusBar.system.removeStatusItem(old) }
            self.setupStatusItem(preferredPosition: position)
            self.updateStatusMetrics(self.monitoring.snapshot)
            return self.item
        }
        MenuBarOrganizer.shared.start()
        DashboardWindow.refreshGlobalHotkeys()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshDockLockState), name: DockLock.stateChanged, object: lock)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshLanguage), name: L10n.changed, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance), name: .appearanceModeChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatusMetrics), name: .statusMetricsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(mediaMonitoringSettingsChanged), name: .mediaMonitoringSettingsChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatusMetrics), name: .mediaAccessStateChanged, object: nil)
        MediaAccessMonitor.shared.configureFromPreferences()
        NotificationCenter.default.addObserver(self, selector: #selector(previewResourceAlerts), name: .resourceAlertPreview, object: nil)
        monitoring.onSample = { [weak self] sample in self?.updateStatusMetrics(sample) }
        monitoring.start()
        // Resume only our existing approved filter; this performs no activation or preference save.
        if SystemExtensionController.preflight(bundleID: ContentFilterConfiguration.bundleID) == nil {
            ContentFilterConfiguration.shared.refresh()
        }
        if !attemptStart() {
            waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                if self?.attemptStart() == true { timer.invalidate() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showOverview()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MenuBarOrganizer.shared.expandForArrangement()
        showOverview()
        return true
    }

    @objc private func refreshLanguage() {
        setBaseStatusToolTip(L10n.text("AI Lock 总览"))
        updateStatusMetrics(monitoring.snapshot)
    }

    @objc private func refreshAppearance() {
        guard let window = overviewPopover.contentViewController?.view.window else { return }
        window.appearance = DashboardWindow.preferredAppearance
    }

    private func updateStatusMetrics(_ sample: SystemSnapshot) {
        let selected = (UserDefaults.standard.string(forKey: "overview.statusMetrics") ?? "")
            .split(separator: ",")
            .map(String.init)
        var active = statusAlerts.evaluate(sample)
        if Date() < alertPreviewUntil { active.formUnion(ResourceAlerts.Metric.allCases) }
        if active.isEmpty {
            alertBlinkTimer?.invalidate()
            alertBlinkTimer = nil
            alertBlinkBright = true
        } else if alertBlinkTimer == nil {
            alertBlinkBright = true
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.alertBlinkBright.toggle()
                self.updateStatusMetrics(self.monitoring.snapshot)
            }
            alertBlinkTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
        var items: [NSAttributedString] = []
        let networkSelected = selected.contains("network") || selected.contains("networkUpload") || selected.contains("networkDownload")
        let visibleMetrics = ResourceAlerts.Metric.allCases.filter {
            selected.contains($0.rawValue) || ($0 == .network && networkSelected) || active.contains($0)
        }
        for metric in visibleMetrics {
            let isAlert = active.contains(metric)
            let symbol: String
            let value: String
            switch metric {
            case .cpu:
                symbol = "cpu"
                value = statusPercent(sample.cpuUsage * 100)
            case .memory:
                symbol = "memorychip"
                value = statusPercent(sample.memoryTotal > 0 ? Double(sample.memoryUsed) / Double(sample.memoryTotal) * 100 : 0)
            case .disk:
                symbol = "internaldrive"
                value = isAlert ? formattedBytes(sample.diskTotal > sample.diskUsed ? sample.diskTotal - sample.diskUsed : 0) : statusPercent(sample.diskTotal > 0 ? Double(sample.diskUsed) / Double(sample.diskTotal) * 100 : 0)
            case .swap:
                symbol = "arrow.left.arrow.right"
                value = formattedBytes(sample.swapUsed)
            case .battery:
                symbol = "battery.25percent"
                value = sample.batteryPercent.map { statusPercent(Double($0)) } ?? "—   "
            case .thermal:
                symbol = "thermometer"
                value = L10n.text(sample.thermalLevel >= 3 ? "严重" : (sample.thermalLevel >= 2 ? "偏高" : "正常"))
            case .network:
                symbol = "network"
                value = "↓ \(compactRate(sample.networkDownload)) ↑ \(compactRate(sample.networkUpload))"
            case .camera:
                symbol = "video.fill"
                value = L10n.text(isAlert ? "使用中" : "未监视")
            case .microphone:
                symbol = "mic.fill"
                value = L10n.text(isAlert ? "使用中" : "未监视")
            }
            let group = NSMutableAttributedString(attributedString: metricAttachment(symbol, description: metric.rawValue))
            group.append(statusSpacing(2))
            group.append(statusValue(value, isAlert: isAlert, isLast: metric == visibleMetrics.last))
            items.append(group)
        }
        let title = NSMutableAttributedString(string: "")
        if !items.isEmpty { title.append(statusSpacing(4)) }
        for (index, group) in items.enumerated() {
            if index > 0 { title.append(statusSpacing(5)) }
            title.append(group)
        }
        if visibleMetrics.contains(.network) {
            networkToolTipIsVisible = true
            item.button?.toolTip = L10n.isEnglish
                ? "Network rate · Download: \(formattedRate(sample.networkDownload)) · Upload: \(formattedRate(sample.networkUpload))"
                : "网络速率 · 下行：\(formattedRate(sample.networkDownload)) · 上行：\(formattedRate(sample.networkUpload))"
        } else if networkToolTipIsVisible {
            networkToolTipIsVisible = false
            item.button?.toolTip = baseStatusToolTip
        }
        item.button?.attributedTitle = title
        item.length = NSStatusItem.variableLength
        item.button?.invalidateIntrinsicContentSize()
        item.button?.needsLayout = true
    }

    // Reserve four monospaced characters, with padding after the value so the
    // number stays close to its icon while the next group never shifts.
    private func statusPercent(_ value: Double) -> String {
        String(format: "%.0f%%", value).padding(toLength: 4, withPad: " ", startingAt: 0)
    }

    private func setBaseStatusToolTip(_ value: String) {
        baseStatusToolTip = value
        if !networkToolTipIsVisible { item?.button?.toolTip = value }
    }

    private func compactRate(_ bytesPerSecond: UInt64) -> String {
        var value = Double(bytesPerSecond)
        var scale = 0
        while value >= 1_000 && scale < 6 {
            value /= 1_000
            scale += 1
        }
        let number = String(format: value < 10 ? "%.1f" : "%.0f", value)
        return String(repeating: " ", count: max(0, 4 - number.count)) + number
    }

    private func statusValue(_ value: String, isAlert: Bool, isLast: Bool) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: statusMetricFontSize, weight: .medium)
        // Trim the final group instead of moving reserved whitespace between
        // its icon and number. Other groups retain their stable width.
        let displayedValue = isLast ? value.trimmingCharacters(in: .whitespaces) : value
        let text = NSAttributedString(string: displayedValue, attributes: [.font: font, .foregroundColor: isAlert ? NSColor.white : NSColor.labelColor])
        // Both states reserve the same bounds, so triggering or pulsing an alert
        // never changes the position of neighboring metrics.
        let reservedWidth = text.size().width
        let size = NSSize(width: ceil(reservedWidth) + 8, height: 20)
        let background = NSColor(srgbRed: alertBlinkBright ? 0.72 : 0.52, green: 0.08, blue: 0.13, alpha: 1)
        let image = NSImage(size: size, flipped: false) { rect in
            if isAlert {
                let badge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
                background.setFill()
                badge.fill()
                NSColor.white.withAlphaComponent(0.45).setStroke()
                badge.lineWidth = 0.5
                badge.stroke()
            }
            text.draw(at: NSPoint(x: 4, y: (size.height - text.size().height) / 2))
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = value.trimmingCharacters(in: .whitespaces) + (isAlert ? L10n.text("，预警") : "")
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - size.height) / 2, width: size.width, height: size.height)
        return NSAttributedString(attachment: attachment)
    }

    private func statusSpacing(_ width: CGFloat) -> NSAttributedString {
        let attachment = NSTextAttachment()
        attachment.image = NSImage(size: NSSize(width: width, height: 1))
        attachment.bounds = NSRect(x: 0, y: 0, width: width, height: 1)
        return NSAttributedString(attachment: attachment)
    }

    @objc private func previewResourceAlerts() {
        alertPreviewUntil = Date().addingTimeInterval(5)
        updateStatusMetrics(monitoring.snapshot)
    }

    @objc private func refreshStatusMetrics() { updateStatusMetrics(monitoring.snapshot) }

    @objc private func mediaMonitoringSettingsChanged() {
        MediaAccessMonitor.shared.configureFromPreferences()
        updateStatusMetrics(monitoring.snapshot)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopOverviewClickMonitoring()
        MenuBarOrganizer.shared.stop()
        alertBlinkTimer?.invalidate()
        monitoring.stop()
        MediaAccessMonitor.shared.stop()
        NetworkHistory.shared.flush()
        ClipboardHistory.stopSharedIfInitialized()
    }

    private func metricAttachment(_ symbol: String, description: String) -> NSAttributedString {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: L10n.text(description))!
        let sourceSize = image.size
        let iconHeight = statusMetricIconSize
        let aspectRatio = sourceSize.height > 0 ? sourceSize.width / sourceSize.height : 1
        let iconWidth = iconHeight * aspectRatio
        image.size = NSSize(width: iconWidth, height: iconHeight)
        image.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = image
        let font = NSFont.monospacedSystemFont(ofSize: statusMetricFontSize, weight: .medium)
        attachment.bounds = NSRect(x: 0, y: (font.capHeight - iconHeight) / 2, width: iconWidth, height: iconHeight)
        return NSAttributedString(attachment: attachment)
    }

    @objc private func refreshDockLockState() {
        dockLockItem?.state = lock.enabled ? .on : .off
        setBaseStatusToolTip(lock.waitingForAuthorization
            ? "AI Lock：DockLock 等待辅助功能授权，授权后自动启用"
            : L10n.text("AI Lock：本机监控运行中"))
    }

    @discardableResult
    private func attemptStart() -> Bool {
        guard lock.enabled else { return true }
        let trusted = AXIsProcessTrusted()
        guard trusted, lock.start() else {
            log("未就绪：AXIsProcessTrusted=\(trusted) 路径=\(Bundle.main.bundlePath)")
            item?.button?.appearsDisabled = false
            setBaseStatusToolTip(L10n.text("AI Lock：Dock 锁定等待辅助功能授权"))
            dockLockItem?.state = .off
            return false
        }
        item?.button?.appearsDisabled = false
        setBaseStatusToolTip(L10n.text("AI Lock：本机监控运行中"))
        dockLockItem?.state = .on
        return true
    }

    private func setupStatusItem(preferredPosition: Double? = nil) {
        overviewPopover.delegate = self
        let positionKey = "NSStatusItem Preferred Position AILock.Main"
        if let preferredPosition {
            UserDefaults.standard.set(preferredPosition, forKey: positionKey)
        } else if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(299, forKey: positionKey)
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AILock.Main"
        let statusIconURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/StatusIcon.png")
        let statusIcon = NSImage(contentsOf: statusIconURL)
        let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: L10n.text("AI Lock"))
            ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: L10n.text("AI Lock"))!
        let image = statusIcon ?? symbol
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = statusIcon == nil
        item.button?.imagePosition = .imageLeft
        item.button?.image = image
        item.button?.imageScaling = .scaleProportionallyUpOrDown
        log("状态栏图标：\(statusIcon == nil ? "系统回退" : statusIconURL.path)，图像尺寸 \(image.size)")

        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(showOverview(_:))
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setBaseStatusToolTip(L10n.text("AI Lock 总览"))
    }

    @objc private func showOverview(_ sender: Any? = nil) {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            if overviewPopover.isShown { overviewPopover.close() }
            showStatusContextMenu(for: button)
            return
        }
        if overviewPopover.isShown {
            if sender != nil { overviewPopover.performClose(sender) }
        } else {
            DashboardWindow.hideFunctionalWindows()
            overviewPopover.behavior = .transient
            overviewPopover.animates = true
            let overview = DashboardOverviewView()
            let hostingController = NSHostingController(rootView: overview)
            hostingController.view.appearance = DashboardWindow.preferredAppearance
            overviewPopover.contentViewController = hostingController
            hostingController.view.layoutSubtreeIfNeeded()
            overviewPopover.contentSize = NSSize(width: 390, height: ceil(hostingController.view.fittingSize.height))
            overviewPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startOverviewClickMonitoring()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.overviewPopover.isShown,
                      let popoverWindow = self.overviewPopover.contentViewController?.view.window else { return }
                popoverWindow.appearance = DashboardWindow.preferredAppearance
                popoverWindow.level = .statusBar
                popoverWindow.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
                popoverWindow.orderFrontRegardless()
            }
        }
    }

    private func showStatusContextMenu(for button: NSStatusBarButton) {
        let menu = NSMenu()
        menu.appearance = DashboardWindow.preferredAppearance
        let settings = menu.addItem(withTitle: L10n.text("设置"), action: #selector(openSettingsFromStatusMenu(_:)), keyEquivalent: "")
        settings.target = self
        let help = menu.addItem(withTitle: L10n.text("帮助"), action: #selector(openHelpFromStatusMenu(_:)), keyEquivalent: "")
        help.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: L10n.text("退出 AI Lock"), action: #selector(quitFromStatusMenu(_:)), keyEquivalent: "")
        quit.target = self
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height), in: button)
    }

    @objc private func openSettingsFromStatusMenu(_ sender: NSMenuItem) {
        DashboardWindow.openPreferences(section: "通用")
    }

    @objc private func openHelpFromStatusMenu(_ sender: NSMenuItem) {
        DashboardWindow.openPreferences(section: "帮助/关于")
    }

    @objc private func quitFromStatusMenu(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func startOverviewClickMonitoring() {
        stopOverviewClickMonitoring()
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        overviewGlobalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: clicks) { [weak self] _ in
            self?.overviewPopover.close()
        }
        overviewLocalClickMonitor = NSEvent.addLocalMonitorForEvents(matching: clicks) { [weak self] event in
            guard let self, self.overviewPopover.isShown else { return event }
            // Leave controls inside the popover and the status item's toggle alone.
            if let window = self.overviewPopover.contentViewController?.view.window,
               event.window === window {
                return event
            }
            if let button = self.item.button, event.window === button.window {
                let point = button.convert(event.locationInWindow, from: nil)
                if button.bounds.contains(point) { return event }
            }
            self.overviewPopover.close()
            return event
        }
    }

    private func stopOverviewClickMonitoring() {
        if let monitor = overviewLocalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = overviewGlobalClickMonitor { NSEvent.removeMonitor(monitor) }
        overviewLocalClickMonitor = nil
        overviewGlobalClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        stopOverviewClickMonitoring()
    }

    @objc private func toggleLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do { if service.status == .enabled { try service.unregister() } else { try service.register() } }
        catch {
            log("开机自启切换失败：\(error.localizedDescription)")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
        }
        sender.state = service.status == .enabled ? .on : .off
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === settingsMenu {
            dockLockItem?.state = lock.enabled ? .on : .off
            return
        }
        guard menu === screenMenu else {
            if AXIsProcessTrusted() { screenItem?.title = L10n.format("Dock 固定在：%{0}", arguments: [String(describing: lock.targetName)])}
            loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return
        }
        menu.removeAllItems()
        let setting = lock.targetSetting
        let automatic = NSMenuItem(title: L10n.text("自动（主屏优先）"), action: #selector(pickScreen(_:)), keyEquivalent: "")
        automatic.representedObject = "builtin"; automatic.target = self
        automatic.state = setting == "builtin" ? .on : .off; menu.addItem(automatic); menu.addItem(.separator())
        for screen in lock.screenChoices {
            let entry = NSMenuItem(title: L10n.text("\(screen.name)\(screen.isBuiltin ? L10n.text("（内置）") : "")  ·  \(screen.size)"), action: #selector(pickScreen(_:)), keyEquivalent: "")
            entry.representedObject = String(screen.id); entry.target = self
            entry.state = setting == String(screen.id) ? .on : (screen.id == lock.currentTargetID ? .mixed : .off)
            menu.addItem(entry)
        }
    }

    @objc private func pickScreen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        lock.setTarget(value); screenItem?.title = L10n.format("Dock 固定在：%{0}", arguments: [String(describing: lock.targetName)])
    }
}

@main
enum AILockMain {
    static func main() {
        if CommandLine.arguments.contains("--register-login-item") {
            do {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
                print("登录项状态：\(SMAppService.mainApp.status.rawValue)")
                return
            } catch {
                FileHandle.standardError.write(Data("登录项注册失败：\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Keep the app in the menu bar while allowing its windows to receive focus.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
