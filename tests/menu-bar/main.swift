import AppKit
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
// Multiple-display geometry is what prevents a hidden section leaking onto a
// wider external display; empty and huge display sets must stay bounded.
precondition(MenuBarOrganizer.collapsedLength(screenWidths: [1512, 3440]) >= 3440)
precondition(MenuBarOrganizer.collapsedLength(screenWidths: [3440, 1512]) == MenuBarOrganizer.collapsedLength(screenWidths: [1512, 3440]))
precondition(MenuBarOrganizer.collapsedLength(screenWidths: [20_000]) == 10_000)
precondition(MenuBarOrganizer.collapsedLength(screenWidths: []) >= 500)
precondition(MenuBarOrganizer.spacerPosition(after: 300, occupiedPositions: [301, 302]) == 300.5,
             "The collapse spacer must sit between the arrow and Sound at position 301")
let suite = "com.laogu.ailock.menubar-tests." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
let manager = MenuBarOrganizer(defaults: defaults)
manager.start()
precondition(!manager.enabled && manager.expanded, "Disabled feature must leave menu bar alone")
manager.toggle()
precondition(manager.expanded, "Disabled feature must not collapse other applications")
manager.stop(); manager.start(); manager.stop()
// Regression: collapsing must never resize the visible control itself.
if MenuBarOrganizer.supportsFolding {
    defaults.set(true, forKey: MenuBarOrganizer.enabledKey)
    defaults.set(false, forKey: MenuBarOrganizer.autoHideKey)
    UserDefaults.standard.set(200, forKey: "NSStatusItem Preferred Position AILock.Tests.Existing")
    let existing = NSStatusBar.system.statusItem(withLength: 24)
    existing.autosaveName = "AILock.Tests.Existing"
    existing.button?.title = "S"
    UserDefaults.standard.set(299, forKey: "NSStatusItem Preferred Position AILock.Tests.Main")
    var mainEntry = NSStatusBar.system.statusItem(withLength: 120)
    mainEntry.autosaveName = "AILock.Tests.Main"
    mainEntry.button?.title = "AI Lock"
    let active = MenuBarOrganizer(defaults: defaults)
    let restoreMain: (Double) -> NSStatusItem? = { position in
        NSStatusBar.system.removeStatusItem(mainEntry)
        UserDefaults.standard.set(position, forKey: "NSStatusItem Preferred Position AILock.Tests.Main")
        mainEntry = NSStatusBar.system.statusItem(withLength: 120)
        mainEntry.autosaveName = "AILock.Tests.Main"
        mainEntry.button?.title = "AI Lock"
        return mainEntry
    }
    active.keepResident(mainEntry, restore: restoreMain)
    active.start()
    precondition(active.controlLength == 24 && active.hiddenSpaceLength == nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let reflectedControl = Mirror(reflecting: active).children.first { $0.label == "arrow" }!.value
    let control = Mirror(reflecting: reflectedControl).children.first!.value as! NSStatusItem
    precondition(control.button!.window!.frame.maxX <= existing.button!.window!.frame.minX + 2, "New control must appear left of existing items")
    precondition(mainEntry.button!.window!.frame.minX >= control.button!.window!.frame.maxX - 1, "AI Lock must be right of the arrow")
    let screen = control.button!.window!.screen!
    UserDefaults.standard.set(UserDefaults.standard.double(forKey: "NSStatusItem Preferred Position AILock.Organizer.Control") + 2, forKey: "NSStatusItem Preferred Position AILock.Tests.NewEntry")
    let entry = NSStatusBar.system.statusItem(withLength: 24)
    entry.autosaveName = "AILock.Tests.NewEntry"
    entry.button?.title = "T"
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    let before = entry.button!.window!.frame
    precondition(before.maxX <= control.button!.window!.frame.minX + 2)
    precondition(screen.frame.intersects(before), "New entry must start visible")
    var otherEntries: [NSStatusItem] = []
    for (index, width) in [CGFloat(18), CGFloat(48)].enumerated() {
        let name = "AILock.Tests.ExtraEntry.\(index)"
        UserDefaults.standard.set(UserDefaults.standard.double(forKey: "NSStatusItem Preferred Position AILock.Organizer.Control") + Double(50 + index * 80), forKey: "NSStatusItem Preferred Position \(name)")
        let extra = NSStatusBar.system.statusItem(withLength: width)
        extra.autosaveName = name
        extra.button?.title = "\(index)"
        otherEntries.append(extra)
    }
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    active.toggle()
    precondition(!active.expanded && active.controlLength == 24)
    precondition((active.hiddenSpaceLength ?? 0) >= 500)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    precondition(!active.expanded, "Collapse must not fall back to expanded")
    let reflected = Mirror(reflecting: active).children.first { $0.label == "arrow" }!.value
    let arrow = Mirror(reflecting: reflected).children.first!.value as! NSStatusItem
    let frame = arrow.button!.window!.frame
    precondition(NSScreen.screens.contains { $0.frame.intersects(frame) }, "Collapsed arrow must remain on screen")
    precondition(mainEntry.button!.window!.frame.minX >= frame.maxX - 1, "AI Lock must stay right when collapsed")
    precondition(NSScreen.screens.contains { $0.frame.intersects(mainEntry.button!.window!.frame) }, "AI Lock must never hide")
    let entryFrame = entry.button!.window!.frame
    precondition(!NSScreen.screens.contains { $0.frame.intersects(entryFrame) }, "New icon left of arrow must be hidden")
    for extra in otherEntries {
        precondition(!NSScreen.screens.contains { $0.frame.intersects(extra.button!.window!.frame) }, "Every left-hand icon must hide")
    }
    let collapsedImage = control.button!.image!.tiffRepresentation
    active.expandForArrangement()
    precondition(active.expanded && active.controlLength == 24 && active.hiddenSpaceLength == nil)
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    if !NSScreen.screens.contains(where: { $0.frame.intersects(entry.button!.window!.frame) }) {
        precondition(control.button!.image!.tiffRepresentation == collapsedImage, "Arrow must wait for actual expansion")
    }
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    precondition(control.button!.image!.tiffRepresentation != collapsedImage, "Arrow must reflect completed expansion")
    precondition(NSScreen.screens.contains { $0.frame.intersects(entry.button!.window!.frame) })
    NSStatusBar.system.removeStatusItem(mainEntry)
    UserDefaults.standard.set(400, forKey: "NSStatusItem Preferred Position AILock.Tests.Main")
    mainEntry = NSStatusBar.system.statusItem(withLength: 120)
    mainEntry.autosaveName = "AILock.Tests.Main"
    mainEntry.button?.title = "AI Lock"
    active.keepResident(mainEntry, restore: restoreMain)
    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
    precondition(mainEntry.button!.window!.frame.maxX <= control.button!.window!.frame.minX + 2, "Misplaced resident test must start left of arrow")
    active.toggle()
    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
    // During resident relocation the safety guard may restore the expanded
    // layout; the invariant here is that AI Lock stays visible on the right.
    precondition(mainEntry.button!.window!.frame.minX >= control.button!.window!.frame.maxX - 1, "Misplaced AI Lock must return to right")
    precondition(NSScreen.screens.contains { $0.frame.intersects(mainEntry.button!.window!.frame) })
    active.expandForArrangement()
    for extra in otherEntries { NSStatusBar.system.removeStatusItem(extra) }
    NSStatusBar.system.removeStatusItem(entry)
    active.stop()
    NSStatusBar.system.removeStatusItem(mainEntry)
    NSStatusBar.system.removeStatusItem(existing)
}
if MenuBarOrganizer.supportsFolding {
    defaults.set(false, forKey: MenuBarOrganizer.enabledKey)
    manager.start()
    manager.toggleEnabled()
    precondition(manager.enabled && defaults.bool(forKey: MenuBarOrganizer.enabledKey), "Home toggle must enable and persist")
    manager.toggleEnabled()
    precondition(!manager.enabled && !defaults.bool(forKey: MenuBarOrganizer.enabledKey), "Second click must disable and persist")
    manager.stop()
}
let host = NSHostingView(rootView: MenuBarOrganizerSettingsView().padding(24).frame(width: 540, height: 400, alignment: .topLeading).background(Color.white))
let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .aqua)
window.backgroundColor = .white
window.contentView = host; host.frame = NSRect(x: 0, y: 0, width: 540, height: 400); window.makeKeyAndOrderFront(nil)
RunLoop.main.run(until: Date().addingTimeInterval(0.5)); host.layoutSubtreeIfNeeded()
if CommandLine.arguments.count > 1, let image = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
    host.cacheDisplay(in: host.bounds, to: image)
    try image.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
}
window.close()
print("PASS: new entry hides while arrow stays visible, multi-display geometry, lifecycle, settings preview")
