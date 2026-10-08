import AppKit
import SwiftUI
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let lock = DockLock()
    private var item: NSStatusItem!
    private var settingsMenu: NSMenu!
    private var dockLockItem: NSMenuItem?
    private var screenMenu: NSMenu!
    private var screenItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var waitTimer: Timer?
    private let overviewPopover = NSPopover()
    private let overviewMonitor = SystemMonitor()
    private var historyTimer: Timer?

    func applicationDidFinishLaunching(_ note: Notification) {
        DashboardWindow.setDockLockController(lock)
        setupStatusItem()
        NotificationCenter.default.addObserver(self, selector: #selector(refreshStatusMetrics), name: .statusMetricsChanged, object: nil)
        recordNetworkHistory()
        historyTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.recordNetworkHistory()
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

    private func recordNetworkHistory() {
        let sample = overviewMonitor.sample()
        NetworkHistory.shared.record(at: sample.timestamp, downloadBytesPerSecond: sample.networkDownload, uploadBytesPerSecond: sample.networkUpload)
        let selected = (UserDefaults.standard.string(forKey: "overview.statusMetrics") ?? "")
            .split(separator: ",")
            .map(String.init)
        var items: [NSAttributedString] = []
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]
        if selected.contains("cpu") {
            items.append(metricAttachment("cpu", description: "CPU"))
            items.append(NSAttributedString(string: String(format: "%.0f%%", sample.cpuUsage * 100), attributes: attributes))
        }
        if selected.contains("memory") {
            let value = sample.memoryTotal > 0 ? Double(sample.memoryUsed) / Double(sample.memoryTotal) * 100 : 0
            items.append(metricAttachment("memorychip", description: "Memory"))
            items.append(NSAttributedString(string: String(format: "%.0f%%", value), attributes: attributes))
        }
        if selected.contains("disk") {
            let value = sample.diskTotal > 0 ? Double(sample.diskUsed) / Double(sample.diskTotal) * 100 : 0
            items.append(metricAttachment("internaldrive", description: "Disk"))
            items.append(NSAttributedString(string: String(format: "%.0f%%", value), attributes: attributes))
        }
        let title = NSMutableAttributedString(string: " ")
        items.forEach { title.append($0); title.append(NSAttributedString(string: " ")) }
        item.button?.attributedTitle = title
        item.length = NSStatusItem.variableLength
        item.button?.invalidateIntrinsicContentSize()
        item.button?.needsLayout = true
    }

    @objc private func refreshStatusMetrics() { recordNetworkHistory() }

    private func metricAttachment(_ symbol: String, description: String) -> NSAttributedString {
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)!
        image.size = NSSize(width: 12, height: 12)
        image.isTemplate = true
        let attachment = NSTextAttachment()
        attachment.image = image
        return NSAttributedString(attachment: attachment)
    }

    @discardableResult
    private func attemptStart() -> Bool {
        let trusted = AXIsProcessTrusted()
        guard trusted, lock.start() else {
            log("未就绪：AXIsProcessTrusted=\(trusted) 路径=\(Bundle.main.bundlePath)")
            item?.button?.appearsDisabled = false
            item?.button?.toolTip = "AI Lock：Dock 锁定等待辅助功能授权"
            dockLockItem?.state = .off
            return false
        }
        item?.button?.appearsDisabled = false
        item?.button?.toolTip = "AI Lock：本机监控运行中"
        dockLockItem?.state = .on
        return true
    }

    private func setupStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let statusIconURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/StatusIcon.png")
        let statusIcon = NSImage(contentsOf: statusIconURL)
        let symbol = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "AI Lock")
            ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "AI Lock")!
        let image = statusIcon ?? symbol
        image.size = NSSize(width: 22, height: 22)
        image.isTemplate = statusIcon == nil
        item.button?.image = image
        item.button?.imageScaling = .scaleProportionallyUpOrDown
        log("状态栏图标：\(statusIcon == nil ? "系统回退" : statusIconURL.path)，图像尺寸 \(image.size)")

        item.menu = nil
        item.button?.target = self
        item.button?.action = #selector(showOverview(_:))
        item.button?.toolTip = "AI Lock 总览"
    }

    @objc private func showOverview(_ sender: Any? = nil) {
        guard let button = item.button else { return }
        if overviewPopover.isShown {
            if sender != nil { overviewPopover.performClose(sender) }
        } else {
            overviewPopover.behavior = .transient
            overviewPopover.animates = true
            overviewPopover.contentSize = NSSize(width: 390, height: 510)
            overviewPopover.contentViewController = NSHostingController(rootView: DashboardOverviewView())
            overviewPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.async { [weak self] in
                guard let popoverWindow = self?.overviewPopover.contentViewController?.view.window else { return }
                popoverWindow.level = .statusBar
                popoverWindow.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle])
                popoverWindow.orderFrontRegardless()
            }
        }
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
            if AXIsProcessTrusted() { screenItem?.title = "Dock 固定在：\(lock.targetName)" }
            loginItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
            return
        }
        menu.removeAllItems()
        let setting = lock.targetSetting
        let automatic = NSMenuItem(title: "自动（主屏优先）", action: #selector(pickScreen(_:)), keyEquivalent: "")
        automatic.representedObject = "builtin"; automatic.target = self
        automatic.state = setting == "builtin" ? .on : .off; menu.addItem(automatic); menu.addItem(.separator())
        for screen in lock.screenChoices {
            let entry = NSMenuItem(title: "\(screen.name)\(screen.isBuiltin ? "（内置）" : "")  ·  \(screen.size)", action: #selector(pickScreen(_:)), keyEquivalent: "")
            entry.representedObject = String(screen.id); entry.target = self
            entry.state = setting == String(screen.id) ? .on : (screen.id == lock.currentTargetID ? .mixed : .off)
            menu.addItem(entry)
        }
    }

    @objc private func pickScreen(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String else { return }
        lock.setTarget(value); screenItem?.title = "Dock 固定在：\(lock.targetName)"
    }
}

@main
enum AILockMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
