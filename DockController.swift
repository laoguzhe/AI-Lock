//
//  Dock controller retained from the original DockLock utility.
//
//  两道防线：
//   1. 边缘钳制：在非目标屏的 Dock 触发边留一条"隐形墙"，指针进不去，Dock 就不搬家。
//      墙的厚度 edgeMargin 需要现场标定 —— v1 用 4pt 太薄，Dock 的触发热区比这厚得多。
//   2. 自动拽回：万一还是被搬走了（快速甩动、相邻屏放行区等），检测到 Dock 不在目标屏，
//      就把光标瞬移到目标屏底边停一下再放回原位，把 Dock 拽回来。
//
//  所有参数都走 UserDefaults，改参数不用重编（重编=临时签名变化=要重新授权，很烦）：
//      defaults write com.laogu.ailock edgeMargin -int 24
//      defaults write com.laogu.ailock autoSnap -bool true
//      defaults write com.laogu.ailock verboseLog -bool true
//      defaults write com.laogu.ailock targetDisplay -string builtin   # builtin|main|<显示器ID>
//

import Cocoa
import CoreGraphics
import ApplicationServices
import OSLog

// MARK: - 配置（每 3 秒热重载，改完立刻生效）

struct Config {
    var edgeMargin: CGFloat = 6      // 隐形墙厚度(点)。太薄拦不住，太厚会觉得屏幕底部够不到
    var warpAssist = false           // 钳制时额外 warp 光标。默认关：会导致底边鼠标卡顿，见 handle()
    var autoSnap = true              // 第二道防线：Dock 跑偏时自动拽回
    var snapHoldMs = 500             // 拽回时在目标屏底边停留多久（太短 Dock 来不及响应）
    var idleBeforeSnapMs = 500       // 光标静止多久才允许拽回，避免打断正在操作的鼠标
    var verboseLog = false           // 详细日志（标定墙厚度时打开）
    /// 锁到哪块屏：builtin=内置屏(默认) / main=主屏 / 直接填 CGDirectDisplayID 数字（台式机多外接时用）
    var targetDisplay = "builtin"

    static func load(defaults d: UserDefaults = .standard) -> Config {
        var c = Config()
        if d.object(forKey: "edgeMargin") != nil { c.edgeMargin = CGFloat(SettingValue.read("edgeMargin", fallback: 6, defaults: d)) }
        if d.object(forKey: "warpAssist") != nil { c.warpAssist = d.bool(forKey: "warpAssist") }
        if d.object(forKey: "autoSnap") != nil { c.autoSnap = d.bool(forKey: "autoSnap") }
        if d.object(forKey: "snapHoldMs") != nil { c.snapHoldMs = min(2000, max(160, d.integer(forKey: "snapHoldMs"))) }
        if d.object(forKey: "idleBeforeSnapMs") != nil { c.idleBeforeSnapMs = min(10000, max(200, d.integer(forKey: "idleBeforeSnapMs"))) }
        if d.object(forKey: "verboseLog") != nil { c.verboseLog = d.bool(forKey: "verboseLog") }
        if let t = d.string(forKey: "targetDisplay") { c.targetDisplay = t }
        return c
    }
}

// MARK: - 日志

let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/AILock.log")
private let logFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
}()

private let appLogger = Logger(subsystem: "com.laogu.ailock", category: "application")
private let logQueue = DispatchQueue(label: "com.laogu.ailock.file-log", qos: .utility)

func log(_ msg: String) {
    appLogger.notice("\(msg, privacy: .public)")
    logQueue.async {
        let line = "[\(logFmt.string(from: Date()))] \(msg)\n"
        let manager = FileManager.default
        if let size = (try? manager.attributesOfItem(atPath: logURL.path)[.size]) as? NSNumber, size.intValue > 1_048_576 {
            let archive = logURL.appendingPathExtension("1")
            try? manager.removeItem(at: archive)
            try? manager.moveItem(at: logURL, to: archive)
        }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
        } else { try? line.write(to: logURL, atomically: true, encoding: .utf8) }
    }
}

/// Dock 停靠边
enum DockEdge: String {
    case bottom, left, right
    static var current: DockEdge {
        let raw = UserDefaults(suiteName: "com.apple.dock")?.string(forKey: "orientation") ?? "bottom"
        return DockEdge(rawValue: raw) ?? .bottom
    }
}

// MARK: - 读取 Dock 实际所在位置（辅助功能 API）
//  不用 CGWindowListCopyWindowInfo：macOS 14+ 起读别的进程窗口要"屏幕录制"权限，太重。
//  AX 只需要我们已有的"辅助功能"权限，且 AXPosition 与 CGDisplayBounds 同为全局坐标(y 向下)。

enum DockProbe {
    static func frame() -> CGRect? {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        // Dock 本体是那个 AXList；其余是 Exposé/Mission Control 之类的辅助元素
        var fallback: CGRect?
        for child in children {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(child, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? "?"
            guard let r = rect(of: child) else { continue }
            if role == kAXListRole as String { return r }
            if fallback == nil { fallback = r }
        }
        return fallback
    }

    private static func rect(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?, sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(posRef as! AXValue, .cgPoint, &p),
              AXValueGetValue(sizeRef as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// 把 Dock 各子元素的角色/位置打进日志，排查用
    static func dump() {
        guard let dock = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            log("AX: 找不到 Dock 进程"); return
        }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        var childrenRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &childrenRef)
        guard err == .success, let children = childrenRef as? [AXUIElement] else {
            log("AX: 读 Dock children 失败 err=\(err.rawValue)"); return
        }
        for (i, c) in children.enumerated() {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(c, kAXRoleAttribute as CFString, &roleRef)
            let r = rect(of: c)
            log("AX: child[\(i)] role=\(roleRef as? String ?? "?") rect=\(r.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "nil")")
        }
    }
}

// MARK: - 核心

final class DockLock {
    private struct Display {
        let id: CGDirectDisplayID
        let bounds: CGRect      // 全局坐标：原点=主屏左上角，y 向下（与 CGEvent.location 同系）
        let isBuiltin: Bool
    }

    private var displays: [Display] = []
    private var targetID: CGDirectDisplayID = CGMainDisplayID()
    private var edge: DockEdge = .bottom
    private var tap: CFMachPort?
    private var cfg = Config()

    private var lastMoveAt: CFAbsoluteTime = 0
    private var snapping = false
    private var snapTimer: Timer?
    private let syntheticEventTag: Int64 = 0x41494C4B
    private var snapFailures = 0
    private var nextPatrolAt: CFAbsoluteTime = 0

    private var authorizationTimer: Timer?
    var waitingForAuthorization: Bool { authorizationTimer != nil }
    static let stateChanged = Notification.Name("AILock.DockLockStateChanged")
    var enabled = UserDefaults.standard.object(forKey: "dockLock.enabled") as? Bool ?? true

    private func publishEnabledState() {
        UserDefaults.standard.set(enabled, forKey: "dockLock.enabled")
        NotificationCenter.default.post(name: Self.stateChanged, object: self)
    }

    private func resumeAfterAuthorization() {
        guard AXIsProcessTrusted() else { return }
        authorizationTimer?.invalidate(); authorizationTimer = nil
        enabled = true
        if !start() {
            enabled = false
            log("DockLock：已获辅助功能授权，但事件监听创建失败；请重启当前 AI Lock。")
        }
        publishEnabledState()
    }

    private func requestAuthorization() {
        enabled = false
        let appURL = Bundle.main.bundleURL
        let alert = NSAlert()
        alert.messageText = L10n.text("DockLock 需要辅助功能权限")
        alert.informativeText = L10n.format("请授权当前运行的 %{0}。\n当前路径：%{1}\n\n若列表只有 AILock-QuickActions.app 等旧名称，不能只凭名称确认权限。可用列表的“+”添加当前应用。授权后 DockLock 会自动重试，无需反复点击。", arguments: [appURL.lastPathComponent, appURL.path])
        alert.addButton(withTitle: L10n.text("打开辅助功能设置"))
        alert.addButton(withTitle: L10n.text("在 Finder 显示当前应用"))
        alert.addButton(withTitle: L10n.text("取消"))
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { publishEnabledState(); return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if response == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
        // The system prompt is asynchronous; keep the user's enable intent until trust arrives.
        authorizationTimer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            self.resumeAfterAuthorization()
        }
        RunLoop.main.add(authorizationTimer!, forMode: .common)
        resumeAfterAuthorization()
        publishEnabledState()
    }

    @discardableResult
    func toggleEnabled() -> Bool {
        cancelSnap()
        if waitingForAuthorization {
            resumeAfterAuthorization()
            return enabled
        }
        if enabled, let tap {
            enabled = false
            CGEvent.tapEnable(tap: tap, enable: false)
        } else if let tap {
            enabled = true
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            if !AXIsProcessTrusted() {
                requestAuthorization()
                return enabled
            } else {
                enabled = true
                if !start() { enabled = false }
            }
            if !enabled {
                log("DockLock 启动失败：辅助功能授权缺失或 CGEvent tap 创建失败")
            }
            if !enabled, tap == nil {
                enabled = false
            }
        }
        publishEnabledState()
        return enabled
    }

    // MARK: 启动

    func start() -> Bool {
        if tap != nil { return true }
        guard enabled else { return false }
        cfg = Config.load()
        refreshDisplays()
        edge = .current

        let mask: CGEventMask =
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDragged.rawValue) |
            (1 << CGEventType.otherMouseDragged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<DockLock>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,          // 必须 defaultTap，listenOnly 改不了事件坐标
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }            // 基本只有一种原因：没有"辅助功能"权限

        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(),
                           CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refreshDisplays() }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.dock.prefchanged"), object: nil, queue: .main
        ) { [weak self] _ in self?.edge = .current }

        // 配置热重载 + 第二道防线巡检
        Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            let targetChanged = self.cfg.targetDisplay != Config.load().targetDisplay
            self.cfg = Config.load()
            if targetChanged {
                self.refreshDisplays()
                self.snapFailures = 0
                self.nextPatrolAt = 0
            }
        }
        Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            self?.patrol()
        }

        logTopology()
        DockProbe.dump()
        return true
    }

    // MARK: 屏幕拓扑

    private func refreshDisplays() {
        cancelSnap()
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)

        displays = ids.prefix(Int(count)).map {
            Display(id: $0, bounds: CGDisplayBounds($0), isBuiltin: CGDisplayIsBuiltin($0) != 0)
        }
        // 目标屏：配置指定 > 内置屏 > 主屏。最后这层退化很重要——合盖纯外接时若没有内置屏，
        // 不兜底就会没有任何一块屏被当作目标，四面楚歌把所有屏底边全封死。
        if let want = UInt32(cfg.targetDisplay), displays.contains(where: { $0.id == want }) {
            targetID = want
        } else if cfg.targetDisplay == "main" {
            targetID = CGMainDisplayID()
        } else {
            targetID = displays.first(where: { $0.isBuiltin })?.id ?? CGMainDisplayID()
        }
    }

    private func logTopology() {
        for d in displays {
            log("屏 id=\(d.id)\(d.isBuiltin ? "(内置)" : "") x:\(Int(d.bounds.minX))…\(Int(d.bounds.maxX)) y:\(Int(d.bounds.minY))…\(Int(d.bounds.maxY))\(d.id == targetID ? "  ← 目标屏" : "")")
        }
        log("配置 edgeMargin=\(Int(cfg.edgeMargin)) autoSnap=\(cfg.autoSnap) edge=\(edge.rawValue)")
    }

    private func display(containing p: CGPoint) -> Display? {
        displays.first { $0.bounds.contains(p) }
    }

    /// 菜单要用的屏幕条目
    struct ScreenChoice {
        let id: CGDirectDisplayID
        let name: String
        let isBuiltin: Bool
        let size: String
        let bounds: CGRect
    }

    var screenChoices: [ScreenChoice] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return ScreenChoice(id: id, name: name(for: id), isBuiltin: CGDisplayIsBuiltin(id) != 0,
                                size: "\(Int(bounds.width))×\(Int(bounds.height))", bounds: bounds)
        }
    }

    /// 当前实际生效的目标屏 id（自动模式下由内置/主屏推导而来）
    var currentTargetID: CGDirectDisplayID { targetID }
    /// 当前的配置值：builtin / main / 具体 id
    var targetSetting: String { cfg.targetDisplay }
    /// 当前目标屏的可读名称，用于菜单文案
    var targetName: String { name(for: targetID) }

    private func name(for id: CGDirectDisplayID) -> String {
        if displays.first(where: { $0.id == id })?.isBuiltin == true { return L10n.text("主屏") }
        let match = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        return match?.localizedName ?? L10n.format("显示器 %{0}", arguments: [String(id)])
    }

    /// 切换目标屏。改完不用手动搬 Dock —— 巡检会发现它不在新目标屏，自动拽过去。
    func setTarget(_ value: String) {
        cancelSnap()
        UserDefaults.standard.set(value, forKey: "targetDisplay")
        cfg = Config.load()
        refreshDisplays()
        log("目标屏改为 \(value) → 实际 id=\(targetID)（\(targetName)）")
    }

    /// 墙外面是否还贴着另一块屏 —— 贴着就必须放行，否则鼠标跨不过去
    private func hasNeighbor(beyond p: CGPoint) -> Bool {
        displays.contains { $0.bounds.contains(p) }
    }

    private var targetBounds: CGRect {
        displays.first { $0.id == targetID }?.bounds ?? CGDisplayBounds(CGMainDisplayID())
    }

    // MARK: 第一道防线 —— 边缘钳制

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 系统会因超时把 tap 关掉，必须自愈，否则工具"静默失效"
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if enabled, let tap { CGEvent.tapEnable(tap: tap, enable: true); log("event tap 被系统关闭，已重新启用") }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) != syntheticEventTag {
            lastMoveAt = CFAbsoluteTimeGetCurrent()
            // Real mouse input takes priority; never jump back over the user's movement.
            if snapping { cancelSnap() }
        }
        guard enabled, !snapping else { return Unmanaged.passUnretained(event) }

        let loc = event.location
        guard let scr = display(containing: loc), scr.id != targetID else {
            return Unmanaged.passUnretained(event)
        }

        var p = loc
        let m = cfg.edgeMargin
        let probe: CGFloat = 2

        switch edge {
        case .bottom:
            let limit = scr.bounds.maxY - m
            if p.y > limit, !hasNeighbor(beyond: CGPoint(x: p.x, y: scr.bounds.maxY + probe)) {
                p.y = limit
                event.setIntegerValueField(.mouseEventDeltaY, value: 0)
            }
        case .left:
            let limit = scr.bounds.minX + m
            if p.x < limit, !hasNeighbor(beyond: CGPoint(x: scr.bounds.minX - probe, y: p.y)) {
                p.x = limit
                event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            }
        case .right:
            let limit = scr.bounds.maxX - m
            if p.x > limit, !hasNeighbor(beyond: CGPoint(x: scr.bounds.maxX + probe, y: p.y)) {
                p.x = limit
                event.setIntegerValueField(.mouseEventDeltaX, value: 0)
            }
        }

        if p != loc {
            // 只改事件坐标，光标就会跟着走。绝不在这里调 CGWarpMouseCursorPosition：
            // warp 会短暂切断"物理鼠标移动→光标"的联动(约数百毫秒)，而这里是每帧都会走到的
            // 热路径，连续 warp 会把抑制期不断续上，表现为在屏幕底边"鼠标失灵两秒、拖不动"。
            event.location = p
            if cfg.warpAssist { CGWarpMouseCursorPosition(p) }   // 仅当纯改坐标拦不住时才开
            if cfg.verboseLog { log("钳制 屏\(scr.id) \(Int(loc.y))→\(Int(p.y))") }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: 第二道防线 —— 检测 Dock 跑偏并拽回

    private func patrol() {
        guard enabled, cfg.autoSnap, !snapping else { return }
        guard CFAbsoluteTimeGetCurrent() >= nextPatrolAt else { return }   // 退避中
        guard let f = DockProbe.frame(), !f.isEmpty else { return }

        let center = CGPoint(x: f.midX, y: f.midY)
        guard let scr = display(containing: center) else { return }
        guard scr.id != targetID else { snapFailures = 0; return }         // Dock 到位，退避复位

        // 用户正在动鼠标时不抢光标，免得打断操作
        guard (CFAbsoluteTimeGetCurrent() - lastMoveAt) * 1000 >= Double(cfg.idleBeforeSnapMs) else { return }

        // 退避：拽不动就别每 0.6 秒硬拽。连续 warp 会让光标长期处于抑制状态，
        // 表现为"目标屏底部鼠标失灵、Dock 也召不出来"——曾经这样空转了 485 次。
        snapFailures += 1
        let backoff: Double = snapFailures <= 2 ? 0 : (snapFailures <= 4 ? 2 : (snapFailures <= 8 ? 5 : 15))
        nextPatrolAt = CFAbsoluteTimeGetCurrent() + backoff
        if snapFailures == 5 {
            log("拽回连续失败，已降频。把鼠标手动移到目标屏底边一次即可，之后会自动保持")
        }

        log("检测到 Dock 在屏 \(scr.id)，拽回目标屏 \(targetID)（第 \(snapFailures) 次）")
        snapBack()
    }

    private func snapBack() {
        snapping = true
        let saved = CGEvent(source: nil)?.location ?? .zero
        let b = targetBounds
        let lure: CGPoint
        switch edge {
        case .bottom: lure = CGPoint(x: b.midX, y: b.maxY - 1)
        case .left:   lure = CGPoint(x: b.minX + 1, y: b.midY)
        case .right:  lure = CGPoint(x: b.maxX - 1, y: b.midY)
        }
        CGWarpMouseCursorPosition(lure)
        CGAssociateMouseAndMouseCursorPosition(1)   // 立刻恢复"物理鼠标→光标"联动，否则会失灵几百毫秒

        // 关键：warp 只挪光标、不产生任何鼠标事件，而 Dock 判断"该不该搬家"看的是事件流，
        // 所以光 warp 它毫无察觉。必须合成一串真实的 mouseMoved 事件在触发边上微动，才叫得动它。
        let src = CGEventSource(stateID: .hidSystemState)
        var ticks = 0
        let total = max(4, cfg.snapHoldMs / 40)
        let timer = Timer(timeInterval: 0.04, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            ticks += 1
            let jitter: CGPoint
            switch self.edge {
            case .bottom: jitter = CGPoint(x: lure.x + (ticks % 2 == 0 ? 3 : -3), y: lure.y)
            case .left, .right: jitter = CGPoint(x: lure.x, y: lure.y + (ticks % 2 == 0 ? 3 : -3))
            }
            let event = CGEvent(mouseEventSource: src, mouseType: .mouseMoved,
                                mouseCursorPosition: jitter, mouseButton: .left)
            event?.setIntegerValueField(.eventSourceUserData, value: self.syntheticEventTag)
            event?.post(tap: .cghidEventTap)

            if ticks >= total {
                t.invalidate()
                CGWarpMouseCursorPosition(saved)
                CGAssociateMouseAndMouseCursorPosition(1)
                self.snapping = false
                self.snapTimer = nil
            }
        }
        snapTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelSnap() {
        snapTimer?.invalidate()
        snapTimer = nil
        snapping = false
    }
}

// MARK: - 菜单栏小组件
