import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let lock = DockLock()
    private var item: NSStatusItem!
    private var toggleItem: NSMenuItem?
    private var screenMenu: NSMenu!
    private var screenItem: NSMenuItem?
    private var loginItem: NSMenuItem?
    private var waitTimer: Timer?
    private var dashboard: DashboardWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        setupStatusItem()
        showDashboard(nil)
        if !attemptStart() {
            waitTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                if self?.attemptStart() == true { timer.invalidate() }
            }
        }
    }

    @objc private func showDashboard(_ sender: Any?) {
        if dashboard == nil { dashboard = DashboardWindow() }
        dashboard?.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
    }

    @discardableResult
    private func attemptStart() -> Bool {
        let trusted = AXIsProcessTrusted()
        guard trusted, lock.start() else {
            log("未就绪：AXIsProcessTrusted=\(trusted) 路径=\(Bundle.main.bundlePath)")
            item?.button?.appearsDisabled = true
            item?.button?.toolTip = "AI Lock：Dock 锁定等待辅助功能授权"
            toggleItem?.title = "Dock 锁定未授权 · 打开系统设置"
            return false
        }
        item?.button?.appearsDisabled = false
        item?.button?.toolTip = "AI Lock：本机监控运行中"
        toggleItem?.title = "启用 Dock 锁定"
        toggleItem?.state = .on
        return true
    }

    private func setupStatusItem() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "shield.lefthalf.filled", accessibilityDescription: "AI Lock")
            ?? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "AI Lock")

        let menu = NSMenu()
        menu.addItem(withTitle: "打开 AI Lock", action: #selector(showDashboard(_:)), keyEquivalent: "o").target = self
        menu.addItem(.separator())
        let toggle = NSMenuItem(title: "启用 Dock 锁定", action: #selector(toggle(_:)), keyEquivalent: "")
        toggle.target = self; toggle.state = .on; menu.addItem(toggle); toggleItem = toggle

        let screenEntry = NSMenuItem(title: "Dock 固定在…", action: nil, keyEquivalent: "")
        screenMenu = NSMenu(); screenMenu.delegate = self
        screenEntry.submenu = screenMenu; menu.addItem(screenEntry); screenItem = screenEntry

        let login = NSMenuItem(title: "开机自启", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self; login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login); loginItem = login
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出 AI Lock", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        guard AXIsProcessTrusted() else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            return
        }
        lock.enabled.toggle(); sender.state = lock.enabled ? .on : .off
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
