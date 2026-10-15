import SQLite3
import AppKit
import Carbon
import CryptoKit
import CoreServices
import UserNotifications

var checks = 0
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    guard condition() else { fputs("FAIL: \(name)\n", stderr); exit(1) }
    checks += 1
    print("PASS: \(name)")
}
let root = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-regression-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let suite = "com.laogu.ailock.tests.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }

// Multiple descriptors, IPv6, process boundaries, and connection state changes.
let sockets = "p123\ncDemo\nf10\nn127.0.0.1:1000->1.1.1.1:443\nTST=ESTABLISHED\nf11\nn[::1]:1001->[::2]:443\nTST=CLOSE_WAIT\np456\ncOther\nf2\nn*:8080\nTST=LISTEN\n"
let connections = NetworkInspector.parse(sockets)
expect(connections.count == 3, "same PID retains multiple TCP sockets")
expect(Set(connections.map(\.id)).count == 3, "socket identity is unique")
expect(connections[1].remote == "[::2]:443" && connections[2].state == "LISTEN", "IPv6 and per-socket state")
let changed = NetworkInspector.parse(sockets.replacingOccurrences(of: "CLOSE_WAIT", with: "ESTABLISHED"))
expect(connections.map(\.id) == changed.map(\.id), "state change does not invent a new connection")
expect(NetworkInspector.parse("").isEmpty, "empty socket result")

var commandGesture = CommandDoubleTapDetector()
expect(!commandGesture.update(commandDown: true, otherKey: false, timestamp: 1), "first Command down waits")
expect(!commandGesture.update(commandDown: false, otherKey: false, timestamp: 1.1), "first Command release waits")
expect(!commandGesture.update(commandDown: true, otherKey: false, timestamp: 1.2), "second Command down waits for release")
expect(commandGesture.update(commandDown: false, otherKey: false, timestamp: 1.3), "two short Command taps open launcher")
_ = commandGesture.update(commandDown: true, otherKey: false, timestamp: 2)
_ = commandGesture.update(commandDown: true, otherKey: true, timestamp: 2.05)
_ = commandGesture.update(commandDown: false, otherKey: false, timestamp: 2.1)
_ = commandGesture.update(commandDown: true, otherKey: false, timestamp: 2.2)
expect(!commandGesture.update(commandDown: false, otherKey: false, timestamp: 2.3), "Command shortcut cancels double tap")
commandGesture.reset()
_ = commandGesture.update(commandDown: true, otherKey: false, timestamp: 3)
_ = commandGesture.update(commandDown: false, otherKey: false, timestamp: 3.6)
_ = commandGesture.update(commandDown: true, otherKey: false, timestamp: 3.7)
expect(!commandGesture.update(commandDown: false, otherKey: false, timestamp: 3.8), "held Command is not a tap")

let expectedCodes = [kVK_ANSI_1,kVK_ANSI_2,kVK_ANSI_3,kVK_ANSI_4,kVK_ANSI_5,kVK_ANSI_6,kVK_ANSI_7,kVK_ANSI_8,kVK_ANSI_9].map(UInt32.init)
expect((1...9).compactMap(HotkeyConfiguration.numberKeyCode) == expectedCodes, "all nine numeric hotkeys")
expect(HotkeyConfiguration.numberKeyCode(0) == nil && HotkeyConfiguration.numberKeyCode(10) == nil, "invalid hotkey assignment")
expect(HotkeyConfiguration.quickActionID != HotkeyConfiguration.searchID, "Space actions have distinct identifiers")
expect(ApplicationLocations.searchableRoots.contains { $0.path == "/Applications" }, "search includes third-party applications")
expect(ApplicationLocations.removableRoots.contains { $0.path == "/Applications" }, "uninstall includes third-party applications")
expect(!ApplicationLocations.removableRoots.contains { $0.path.hasPrefix("/System") }, "system application roots cannot be uninstalled")
let file = root.appendingPathComponent("prefs.plist")
try Data(repeating: 65, count: 8192).write(to: file)
expect(ApplicationUninstaller.diskSize(file) > 0, "ordinary preference file has allocated size")
let outside = root.appendingPathComponent("outside")
let inside = root.appendingPathComponent("inside")
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
let link = inside.appendingPathComponent("link")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
expect(!ApplicationLocations.contains(link.appendingPathComponent("file"), in: inside), "parent symlink cannot escape a root")
let malicious = InstalledApplication(url: root.appendingPathComponent("bad.app"), name: "Fixture", bundleID: "../../Documents", size: 0)
expect(ApplicationUninstaller.relatedItems(for: malicious).isEmpty, "malformed bundle ID cannot create residual paths")
expect(!ApplicationUninstaller.uninstall(malicious, relatedItems: []), "uninstall refuses an out-of-root application")

expect(SettingValue.saveThresholds([("alert.cpu", 75), ("alert.memory", 85), ("alert.diskGB", 0.5), ("alert.networkMB", 0.5)], defaults: defaults), "valid thresholds save as one update")
expect(!SettingValue.saveThresholds([("alert.cpu", 60), ("alert.memory", 101)], defaults: defaults) && defaults.double(forKey: "alert.cpu") == 75, "invalid threshold leaves all settings unchanged")
expect(SettingValue.validated(.infinity, key: "alert.diskGB") == nil && SettingValue.validated(.nan, key: "alert.networkMB") == nil, "non-finite thresholds rejected")
defaults.set(Double.greatestFiniteMagnitude, forKey: "alert.diskGB")
expect(SettingValue.read("alert.diskGB", fallback: 10, defaults: defaults) == 10, "corrupt persisted threshold falls back safely")
expect(SettingValue.validated(6.5, key: "edgeMargin") == 6.5 && SettingValue.validated(-1, key: "edgeMargin") == nil, "fractional Dock margin preserved and invalid margin rejected")

defaults.set(6.5, forKey: "edgeMargin")
expect(Config.load(defaults: defaults).edgeMargin == 6.5, "Dock configuration reads fractional margins from the shared key")

var parser = NetTopParser()
parser.ingest("time interface state bytes_in bytes_out\n01:00:00 Helper Name.123 100 200\n", timestamp: 10)
parser.ingest("time interface state bytes_in bytes_out\n01:00:01 Helper Na", timestamp: 11)
parser.ingest("me.123 200 400\n", timestamp: 11)
parser.ingest("time interface state bytes_in bytes_out\n", timestamp: 12)
expect(parser.rates[123]?.down == 100 && parser.rates[123]?.up == 200, "nettop chunking and names containing spaces")
var buffered = NetTopParser()
buffered.ingest("time\n01:00:00 Name.321 100 100\ntime\n01:00:01 Name.321 200 300\ntime\n01:00:02 Name.321 300 500\n", timestamp: 500)
expect(buffered.rates[321]?.down == 100 && buffered.rates[321]?.up == 200, "multiple frames in one pipe read use the sample timestamps")
parser = NetTopParser()
expect(parser.rates.isEmpty, "nettop reset discards old rates and baseline")
parser.ingest("time\n01:00:01 Name.123 bad 1 200\ntime\n", timestamp: 15)
expect(parser.rates.isEmpty, "malformed nettop numbers do not shift columns")

let key = SymmetricKey(data: Data(repeating: 23, count: 32))
let historyURL = root.appendingPathComponent("history.bin")
let pasteboard = NSPasteboard.withUniqueName()
defer { pasteboard.releaseGlobally() }
let history = ClipboardHistory(fileURL: historyURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
let initialPasteboard = NSPasteboard.withUniqueName()
initialPasteboard.setString("copied before opening", forType: .string)
let initialHistory = ClipboardHistory(fileURL: root.appendingPathComponent("initial-clipboard.bin"), defaults: defaults, pasteboard: initialPasteboard, keyProvider: { key })
expect(initialHistory.readCurrentClipboard(), "clipboard reads content copied before opening")
expect(initialHistory.records.first?.plainText == "copied before opening", "initial clipboard content is captured")
initialHistory.setPaused(true)
initialPasteboard.clearContents(); initialPasteboard.setString("must remain paused", forType: .string)
expect(!initialHistory.readCurrentClipboard(), "permission retry respects paused collection")
expect(initialHistory.records.count == 1, "retry does not capture while paused")
initialHistory.setPaused(false)
initialHistory.stop(); initialPasteboard.releaseGlobally()
let first = NSPasteboardItem(); first.setString("file:///tmp/first.txt", forType: .fileURL)
let second = NSPasteboardItem(); second.setString("file:///tmp/second.txt", forType: .fileURL)
history.capture([first, second], sourceBundleID: "test.fixture")
expect(history.records.count == 1 && history.records[0].items.count == 2, "clipboard captures all objects from one copy")
history.copyBack(history.records[0])
expect(pasteboard.pasteboardItems?.count == 2 && pasteboard.pasteboardItems?[1].string(forType: .fileURL) == "file:///tmp/second.txt", "clipboard restores multiple file references in order")
history.stop()
let encrypted = try Data(contentsOf: historyURL)
expect((try? AES.GCM.open(AES.GCM.SealedBox(combined: encrypted), using: key)) != nil, "history persists with authenticated encryption")
let text = NSPasteboardItem(); text.setString("secret", forType: .string); text.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
history.capture([text], sourceBundleID: "test.fixture")
expect(history.records.count == 1, "confidential pasteboard entries are not captured")
history.setPaused(true)
history.capture([first], sourceBundleID: "other.fixture")
expect(history.records.count == 1, "paused history does not capture changes")
history.setPaused(false)
history.exclude(bundleID: "excluded.fixture")
history.capture([second], sourceBundleID: "excluded.fixture")
expect(history.records.count == 1, "excluded source is not captured")
history.exclude(bundleID: "excluded.fixture")
expect(history.excludedBundleIDs == ["excluded.fixture"], "application exclusions are persisted without duplicates")
let exclusionReader = ClipboardHistory(fileURL: root.appendingPathComponent("unused.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
expect(exclusionReader.excludedBundleIDs == ["excluded.fixture"], "application exclusion survives history instance recreation")
history.include(bundleID: "excluded.fixture")
expect(history.excludedBundleIDs.isEmpty, "application can be removed from clipboard exclusions")
exclusionReader.capture([second], sourceBundleID: "excluded.fixture")
expect(exclusionReader.records.count == 1, "restored application can contribute new clipboard records")
history.exclude(bundleID: "excluded.fixture")

let huge = NSPasteboardItem(); huge.setData(Data(repeating: 1, count: ClipboardHistory.maximumRecordBytes + 1), forType: .png)
history.capture([huge], sourceBundleID: "test.fixture")
expect(history.records.count == 1, "oversized copy is rejected in its entirety")
expect(history.oversizedContentSkipped, "oversized copy exposes a visible size-limit warning")
history.capture([second], sourceBundleID: "test.fixture")
expect(!history.oversizedContentSkipped, "next supported copy clears the size-limit warning")

struct LegacyRecord: Codable {
    let id: UUID; let capturedAt: Date; let sourceBundleID: String; let types: [String]; let values: [String: Data]
}
let oldRecord = LegacyRecord(id: UUID(), capturedAt: Date().addingTimeInterval(-2 * 86400), sourceBundleID: "test.fixture", types: ["public.utf8-plain-text"], values: ["public.utf8-plain-text": Data("legacy".utf8)])
let legacyURL = root.appendingPathComponent("legacy.bin")
let sealed = try AES.GCM.seal(JSONEncoder().encode([oldRecord]), using: key).combined!
try sealed.write(to: legacyURL)
defaults.set(3, forKey: "clipboard.retentionDays")
let legacy = ClipboardHistory(fileURL: legacyURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
expect(legacy.records.first?.preview == "legacy", "existing encrypted history schema remains readable")
expect((try? Data(contentsOf: legacyURL)) == sealed, "constructing a history reader never rewrites the file")
legacy.retentionDays = 1
legacy.stop()
expect(legacy.records.isEmpty, "shortening retention prunes shared state immediately")
legacy.retentionDays = 3
legacy.capture([first], sourceBundleID: "test.fixture")
legacy.stop()
expect(!legacy.records.contains { $0.id == oldRecord.id }, "extending retention never resurrects removed entries")
legacy.prune(now: Date().addingTimeInterval(4 * 86400)); legacy.stop()
expect(legacy.records.isEmpty, "expiration works without a new clipboard change")
legacy.clear(); legacy.stop()
let reloaded = ClipboardHistory(fileURL: legacyURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
expect(reloaded.records.isEmpty, "cleared history remains empty on reload")
let damagedURL = root.appendingPathComponent("damaged.bin")
let damaged = Data("invalid ciphertext".utf8); try damaged.write(to: damagedURL)
let damagedHistory = ClipboardHistory(fileURL: damagedURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
damagedHistory.capture([first], sourceBundleID: "test.fixture"); damagedHistory.stop()
expect((try? Data(contentsOf: damagedURL)) == damaged, "failed decryption preserves the original file")

damagedHistory.clear(); damagedHistory.stop()
expect(!FileManager.default.fileExists(atPath: damagedURL.path), "explicit clear removes an unreadable history without a key")

// Transient Keychain failures must recover without clearing or overwriting history.
let retryURL = root.appendingPathComponent("retry-history.bin")
try sealed.write(to: retryURL)
var retryKeyAvailable = false
let retryHistory = ClipboardHistory(fileURL: retryURL, defaults: defaults, pasteboard: pasteboard,
                                    keyProvider: { retryKeyAvailable ? key : nil })
expect(retryHistory.storageError?.contains("加密密钥") == true, "missing key reports an actionable error")
expect((try? Data(contentsOf: retryURL)) == sealed, "key failure preserves encrypted history")
retryKeyAvailable = true
let retryDeadline = Date().addingTimeInterval(5)
while retryHistory.storageError != nil && Date() < retryDeadline {
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
}
expect(!retryHistory.isLoadingHistory && retryHistory.storageError == nil && retryHistory.records.first?.preview == "legacy",
       "automatic retry recovers history after transient key access failure")
retryHistory.capture([first], sourceBundleID: "test.fixture"); retryHistory.stop()
let retryReader = ClipboardHistory(fileURL: retryURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
expect(retryReader.records.count == 2, "successful retry re-enables persistence")

let cancelledRetryURL = root.appendingPathComponent("cancelled-retry.bin")
try sealed.write(to: cancelledRetryURL)
var cancelledRetryCalls = 0
let cancelledRetryHistory = ClipboardHistory(fileURL: cancelledRetryURL, defaults: defaults, pasteboard: pasteboard,
                                             keyProvider: { cancelledRetryCalls += 1; return nil })
cancelledRetryHistory.stop()
RunLoop.main.run(until: Date().addingTimeInterval(1.1))
expect(cancelledRetryCalls == 1, "stopping history cancels automatic read retries")

let boundedURL = root.appendingPathComponent("bounded.bin")
let many = (0...ClipboardHistory.maximumRecords).map { index in
    ClipboardRecord(capturedAt: Date(), sourceBundleID: "test.fixture", items: [["public.utf8-plain-text": Data("record \(index)".utf8)]])
}
try AES.GCM.seal(JSONEncoder().encode(many), using: key).combined!.write(to: boundedURL)
let bounded = ClipboardHistory(fileURL: boundedURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key })
expect(bounded.records.count == ClipboardHistory.maximumRecords, "history loading enforces its record-count limit")

let alerts = ResourceAlerts(defaults: defaults)
var value = SystemSnapshot.empty
value.cpuUsage = 0.95
expect(alerts.evaluate(value) == [.cpu], "CPU alert is active without an invalid disk alert")
expect(alerts.evaluate(value) == [.cpu], "ongoing alert remains active without cooldown")
value.memoryTotal = 100
value.memoryUsed = 85
value.memoryPressure = "严重"
value.diskTotal = 100_000_000_000
value.diskUsed = 95_000_000_000
value.networkDownload = 60_000_000
expect(alerts.evaluate(value) == Set([.cpu, .memory, .disk, .network]), "all resource alerts are represented and memory is deduplicated")
value = .empty
expect(alerts.evaluate(value).isEmpty, "recovered alerts clear immediately")
value.memoryPressure = "偏高"
expect(alerts.evaluate(value) == [.memory], "memory pressure alone triggers the memory indicator")
value = .empty
value = .empty
value.swapUsed = 4_000_000_000
value.batteryPercent = 20
value.isOnBattery = true
value.thermalLevel = 2
expect(alerts.evaluate(value) == [.battery, .thermal], "low battery and thermal alerts trigger; swap usage alone is not memory pressure")
value.isOnBattery = false
expect(!alerts.evaluate(value).contains(.battery), "low battery alert clears when external power is connected")
value.batteryPercent = nil
value.isOnBattery = true
expect(!alerts.evaluate(value).contains(.battery), "unavailable battery data never triggers")
defaults.set(3, forKey: "alert.thermalLevel")
expect(!alerts.evaluate(value).contains(.thermal), "critical-only setting ignores serious thermal pressure")
value.thermalLevel = 3
expect(alerts.evaluate(value).contains(.thermal), "critical thermal pressure triggers critical-only setting")
expect(SettingValue.validated(2.5, key: "alert.thermalLevel") == nil, "thermal level rejects fractional values")
value = .empty
var samples = 0
let service = MonitoringService(sample: { samples += 1; return value }, alerts: alerts, recordHistory: { _ in })
service.start(interval: 0.02); service.start(interval: 0.02)
RunLoop.main.run(until: Date().addingTimeInterval(0.08))
expect(samples >= 3, "background monitoring ticks without any dashboard view")
service.stop()
let stopped = samples
RunLoop.main.run(until: Date().addingTimeInterval(0.06))
expect(samples == stopped, "monitoring stop invalidates its timer")

expect((try? CommandRunner.run("/bin/echo", arguments: ["fixture"]).trimmingCharacters(in: .whitespacesAndNewlines)) == "fixture", "background command returns output")
do { _ = try CommandRunner.run("/bin/sleep", arguments: ["2"], timeout: 0.02); expect(false, "command timeout") }
catch CommandError.timedOut { expect(true, "hung sampling command has a bounded timeout") }
do { _ = try CommandRunner.run("/usr/bin/false", arguments: []); expect(false, "failed command") }
catch CommandError.failed { expect(true, "command failure is distinct from an empty result") }
let own = ProcessMonitor().sample().first { $0.pid == getpid() }
expect(own != nil && !ProcessMonitor.canSignal(own!), "AI Lock refuses to signal its own process")
let identity = MonitoredProcess(pid: getpid(), name: "fixture", executablePath: "/bin/sleep", cpuPercent: 0,
                                memoryBytes: 0, startTime: Date(timeIntervalSince1970: 0), isProtected: false, userID: getuid())
expect(!ProcessMonitor.canSignal(identity), "a stale or mismatched process identity is refused")
// Bulk termination must only act on disposable fixtures, never a live user snapshot.
let ordinaryFixture = Process()
ordinaryFixture.executableURL = URL(fileURLWithPath: "/bin/sleep")
ordinaryFixture.arguments = ["30"]
let stubbornFixture = Process()
stubbornFixture.executableURL = URL(fileURLWithPath: "/bin/sh")
stubbornFixture.arguments = ["-c", "trap '' TERM; exec /bin/sleep 30"]
try ordinaryFixture.run()
try stubbornFixture.run()
Thread.sleep(forTimeInterval: 0.15)
let fixturePIDs: Set<pid_t> = [ordinaryFixture.processIdentifier, stubbornFixture.processIdentifier]
let bulkSnapshot = ProcessMonitor().sample()
let disposableTargets = ProcessBulkCloser.targets(in: bulkSnapshot.filter { fixturePIDs.contains($0.pid) })
expect(disposableTargets.count == 2, "bulk close includes background command fixtures without GUI applications")
expect(ProcessBulkCloser.targets(in: [own!, identity]).isEmpty, "bulk close excludes self and stale process identities")
let staleFixture = disposableTargets.first.map {
    MonitoredProcess(pid: $0.pid, name: $0.name, executablePath: $0.executablePath, cpuPercent: 0, memoryBytes: 0,
        startTime: Date(timeIntervalSince1970: 0), isProtected: false, userID: getuid())
}!
let staleResults = ProcessBulkCloser.close([staleFixture], gracePeriod: 0, verificationPeriod: 0)
expect(staleResults.count == 1 && ordinaryFixture.isRunning && stubbornFixture.isRunning, "changed identity never receives bulk termination signals")
let bulkResults = ProcessBulkCloser.close(disposableTargets, gracePeriod: 0.3, verificationPeriod: 1)
expect(bulkResults.count == 2 && bulkResults.allSatisfy { $0.exited }, "bulk close verifies normal exit and forced exit of SIGTERM-resistant fixture")
for fixture in [ordinaryFixture, stubbornFixture] {
    if fixture.isRunning { fixture.terminate(); kill(fixture.processIdentifier, SIGKILL) }
    fixture.waitUntilExit()
}
expect(ProcessBulkCloser.close([], gracePeriod: 0, verificationPeriod: 0).isEmpty, "empty confirmed list closes nothing")

let networkMonitor = ProcessNetworkMonitor()
networkMonitor.start(); networkMonitor.start()
RunLoop.main.run(until: Date().addingTimeInterval(3.2))
let liveRates = networkMonitor.currentRates()
networkMonitor.stop()
expect(!liveRates.isEmpty && liveRates.values.allSatisfy { $0.down.isFinite && $0.up.isFinite && $0.down >= 0 && $0.up >= 0 }, "live nettop sampling returns finite nonnegative rates")
networkMonitor.stop()
expect(networkMonitor.currentRates().isEmpty, "stopping live nettop removes published rates")
networkMonitor.start(); networkMonitor.stop()
expect(networkMonitor.currentRates().isEmpty, "nettop restart starts with an empty baseline")

var tracker = NetworkCounterTracker()
func counters(_ received: UInt64, _ sent: UInt64 = 0) -> NetworkCounters {
    NetworkCounters(received: received, sent: sent)
}
expect(tracker.sample(["en0": counters(100, 50)], at: 10).download == 0, "network first sample is a baseline")
let normalRate = tracker.sample(["en0": counters(300, 150)], at: 12)
expect(normalRate.download == 100 && normalRate.upload == 50, "network rates use elapsed monotonic seconds")
expect(tracker.sample(["en0": counters(400), "en1": counters(1_000_000)], at: 13).download == 100, "new interface lifetime counters do not create a traffic spike")
expect(tracker.sample(["en0": counters(500)], at: 14).download == 100, "removed interface does not erase surviving interface traffic")
expect(tracker.sample(["en0": counters(20)], at: 15).download == 0, "interface counter reset rebases without underflow")
expect(tracker.sample(["en0": counters(120)], at: 16).download == 100, "counter reset recovers on the next interval")
expect(tracker.sample(nil, at: 17).download == 0, "failed network sampling produces no rate")
expect(tracker.sample(["en0": counters(50_000)], at: 18).download == 0, "network recovery starts a fresh baseline")
expect(tracker.sample(["en0": counters(60_000)], at: 18).download == 0, "zero sampling interval cannot overflow a rate")
expect(tracker.sample(["en0": counters(0)], at: .nan).download == 0, "invalid sample time is rejected")
var overflowTracker = NetworkCounterTracker()
_ = overflowTracker.sample(["a": counters(0), "b": counters(0)], at: 1)
let saturated = overflowTracker.sample(["a": counters(.max), "b": counters(.max)], at: 1.000001)
expect(saturated.download == UInt64.max && saturated.received == UInt64.max, "extreme counters and rates saturate safely")


let scanRoot = root.appendingPathComponent("scan")
try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
for index in 1...12 {
    try Data(repeating: UInt8(index), count: index * 8192).write(to: scanRoot.appendingPathComponent("\(index).pdf"))
}
try Data(repeating: 1, count: 100000).write(to: scanRoot.appendingPathComponent(".hidden"))
try FileManager.default.createSymbolicLink(at: scanRoot.appendingPathComponent("alias"), withDestinationURL: outside)
let scan = FileScanService.scan(root: scanRoot, threshold: 1, limit: 3)
expect(scan.scannedFiles == 12 && scan.matchingFiles == 12 && scan.largestFiles.count == 3, "one scan counts all ordinary files while retaining only top K")
expect(scan.largestFiles.map { $0.url.lastPathComponent } == ["12.pdf", "11.pdf", "10.pdf"], "bounded heap retains the largest files in order")
expect(scan.categories.first?.count == 12 && scan.categories.first?.name == "文档", "categories cover all scanned files independently of top K")
expect(FileScanService.scan(root: scanRoot, threshold: .max).matchingFiles == 0, "large-file threshold does not alter category totals")
let cancelled = ScanCancellation(); cancelled.cancel()
expect(FileScanService.scan(root: scanRoot, cancellation: cancelled).cancelled, "cancelled scan performs no enumeration")
expect(FileScanService.scan(root: file).error != nil, "invalid scan root reports an error rather than empty success")
expect(FileScanService.scan(root: scanRoot, limit: 0).largestFiles.isEmpty, "category-only scan has bounded zero file results")

let catalogRoot = root.appendingPathComponent("applications")
let nestedApp = catalogRoot.appendingPathComponent("Utilities/测试应用.app")
try FileManager.default.createDirectory(at: nestedApp.appendingPathComponent("Contents"), withIntermediateDirectories: true)
let plist: [String: Any] = ["CFBundleIdentifier": "test.catalog", "CFBundleName": "测试应用"]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: nestedApp.appendingPathComponent("Contents/Info.plist"))
let catalog = ApplicationCatalog.scan(roots: [catalogRoot, catalogRoot])
expect(catalog.count == 1 && catalog[0].bundleID == "test.catalog", "shared application catalog recursively discovers and deduplicates applications")
let fields = SearchFields("测试应用")
expect(fields.score("测试应用") == 0 && fields.score("ceshi") != nil && fields.score("csyy") != nil, "precomputed application fields support Chinese, pinyin and initials")

let operationRoot = root.appendingPathComponent("operation")
try FileManager.default.createDirectory(at: operationRoot, withIntermediateDirectories: true)
let firstAction = operationRoot.appendingPathComponent("first")
let secondAction = operationRoot.appendingPathComponent("second")
try Data("first".utf8).write(to: firstAction); try Data("second".utf8).write(to: secondAction)
let operation = FileOperationPlan.prepare(urls: [firstAction, secondAction], roots: [operationRoot])
var moved: [URL] = []
let partialResults = operation.execute { url in
    if url == secondAction { throw NSError(domain: "fixture", code: 1) }
    moved.append(url); return root.appendingPathComponent("trash/first")
}
expect(partialResults.count == 2 && partialResults[0].succeeded && !partialResults[1].succeeded, "file operation reports individual partial failures")
expect(partialResults[0].destination != nil && moved == [firstAction], "successful operation retains recovery destination")
let changedPlan = FileOperationPlan.prepare(urls: [firstAction], roots: [operationRoot])
try FileManager.default.moveItem(at: firstAction, to: operationRoot.appendingPathComponent("old"))
try Data("replacement".utf8).write(to: firstAction)
expect(!changedPlan.execute { _ in expect(false, "changed file must not be moved"); return nil }[0].succeeded, "file identity replacement after review is rejected")
expect(FileOperationPlan.prepare(urls: [file], roots: [operationRoot]).items.isEmpty, "operation planning refuses out-of-root paths")

let repositoryURL = root.appendingPathComponent("clipboard.sqlite")
let repository = ClipboardRepository(url: repositoryURL)
let newRepository = try repository.load(key: key)
expect(newRepository == nil, "new clipboard database has no migration marker")
let storedRecords = [ClipboardRecord(sourceBundleID: "test.repository", items: [["public.utf8-plain-text": Data("private-content-fixture".utf8)]])]
try repository.replace(with: storedRecords, key: key)
let loadedRecords = try ClipboardRepository(url: repositoryURL).load(key: key)!
expect(loadedRecords.count == 1 && loadedRecords[0].items == storedRecords[0].items, "encrypted SQLite records round-trip with identity authentication")
let dbBytes = try Data(contentsOf: repositoryURL)
expect(dbBytes.range(of: Data("private-content-fixture".utf8)) == nil, "clipboard plaintext is absent from SQLite storage")
let extra = ClipboardRecord(sourceBundleID: "test.extra", items: [["public.utf8-plain-text": Data("extra".utf8)]])
try repository.replace(with: storedRecords + [extra], key: key)
try repository.replace(with: [extra], key: key)
let prunedRepository = try repository.load(key: key)
expect(prunedRepository?.map(\.id) == [extra.id], "repository inserts and prunes records transactionally")
do { _ = try ClipboardRepository(url: repositoryURL).load(key: SymmetricKey(size: .bits256)); expect(false, "wrong database key") }
catch { expect(true, "wrong database key cannot decrypt history") }
let migrationURL = root.appendingPathComponent("migration.bin")
try sealed.write(to: migrationURL)
let migrated = ClipboardHistory(fileURL: migrationURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: root.appendingPathComponent("migration.sqlite"))
expect(FileManager.default.fileExists(atPath: migrationURL.path), "opening legacy history does not delete its migration source")
migrated.start(); migrated.stop()
expect(!FileManager.default.fileExists(atPath: migrationURL.path), "legacy history is removed only after committed migration verification")
let migratedReader = ClipboardHistory(fileURL: migrationURL, defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: root.appendingPathComponent("migration.sqlite"))
expect(migratedReader.records.count == migrated.records.count && migratedReader.records.first?.items == migrated.records.first?.items, "migrated history survives restart")
migrated.clear(); migrated.stop()
let clearedRepository = try ClipboardRepository(url: root.appendingPathComponent("migration.sqlite")).load(key: key)
expect(clearedRepository == nil, "explicit clear removes database history without requiring decryption")


var observationCalls = 0
var observationTime: TimeInterval = 10
let observation = NetworkObservationService(fetch: { observationCalls += 1; return connections }, clock: { observationTime })
let observed = try observation.observation()
expect(observed.listeningPorts[456] == [8080], "TCP snapshot also supplies deduplicated listening ports")
observationTime = 11
_ = try observation.observation()
expect(observationCalls == 1, "shared network service reuses a fresh observation")
observationTime = 20
_ = try observation.observation()
expect(observationCalls == 2, "expired network observation is refreshed")
let failedObservation = NetworkObservationService(fetch: { throw NSError(domain: "fixture", code: 1) })
do { _ = try failedObservation.observation(); expect(false, "observation error") }
catch { expect(true, "network backend errors are not converted into empty snapshots") }

let historyMinute = Date(timeIntervalSince1970: 1800000000)
let weighted = NetworkHistory(defaults: defaults, now: historyMinute)
weighted.record(at: historyMinute.addingTimeInterval(10), downloadBytesPerSecond: 100, uploadBytesPerSecond: 0, duration: 1)
weighted.record(at: historyMinute.addingTimeInterval(19), downloadBytesPerSecond: 300, uploadBytesPerSecond: 0, duration: 9)
expect(weighted.snapshot(now: historyMinute.addingTimeInterval(20)).last?.bytesPerSecond == 280, "network history averages rates by observed duration")
let pointCount = weighted.snapshot(now: historyMinute.addingTimeInterval(20)).count
weighted.record(at: historyMinute.addingTimeInterval(25), downloadBytesPerSecond: 900, uploadBytesPerSecond: 0, duration: 0)
expect(weighted.snapshot(now: historyMinute.addingTimeInterval(25)).count == pointCount, "missing network interval is not added as a zero or traffic sample")
weighted.flush()
let restartedHistory = NetworkHistory(defaults: defaults, now: historyMinute.addingTimeInterval(30))
expect(restartedHistory.points.last?.bytesPerSecond == 280, "weighted network history survives restart")
restartedHistory.record(at: historyMinute.addingTimeInterval(19), downloadBytesPerSecond: 900, uploadBytesPerSecond: 0, duration: 9)
expect(restartedHistory.snapshot(now: historyMinute.addingTimeInterval(30)).last?.bytesPerSecond == 280, "network history restart does not double-count already persisted intervals")
let crossing = NetworkHistory(defaults: UserDefaults(suiteName: suite + ".cross")!, now: historyMinute)
defer { UserDefaults(suiteName: suite + ".cross")?.removePersistentDomain(forName: suite + ".cross") }
crossing.record(at: historyMinute.addingTimeInterval(61), downloadBytesPerSecond: 100, uploadBytesPerSecond: 0, duration: 2)
expect(crossing.snapshot(now: historyMinute.addingTimeInterval(62)).count == 2, "network intervals split accurately across minute buckets")
expect(crossing.snapshot(now: historyMinute.addingTimeInterval(62)).allSatisfy { $0.observedSeconds == 1 }, "cross-minute buckets retain their actual coverage")

let asyncService = MonitoringService(sample: {
    var sample = SystemSnapshot.empty
    sample.userCPU = Thread.isMainThread ? 1 : 0
    sample.cpuUsage = 0.1
    return sample
}, alerts: alerts, recordHistory: { _ in }, backgroundSampling: true)
asyncService.start(interval: 10)
RunLoop.main.run(until: Date().addingTimeInterval(0.08))
expect(asyncService.snapshot.cpuUsage == 0.1 && asyncService.snapshot.userCPU == 0, "production-style resource sampling runs off-main and publishes on-main")
asyncService.stop()

let startupRoot = root.appendingPathComponent("launchagents")
try FileManager.default.createDirectory(at: startupRoot, withIntermediateDirectories: true)
try Data("invalid plist".utf8).write(to: startupRoot.appendingPathComponent("broken.plist"))
let startupPlist: [String: Any] = ["Label": "test.missing", "Program": "/nonexistent/test", "RunAtLoad": true]
try PropertyListSerialization.data(fromPropertyList: startupPlist, format: .xml, options: 0).write(to: startupRoot.appendingPathComponent("missing.plist"))
let incompleteStartupPlist: [String: Any] = ["ProgramArguments": [String](), "RunAtLoad": true]
try PropertyListSerialization.data(fromPropertyList: incompleteStartupPlist, format: .xml, options: 0).write(to: startupRoot.appendingPathComponent("incomplete.plist"))
let startup = StartupItemInspector.scan(roots: [(startupRoot, "当前用户 LaunchAgent")])
expect(startup.count == 3 && startup.contains { $0.startupStatus.contains("无法解析") }, "startup inspector keeps malformed configuration visible")
expect(startup.contains { $0.startupStatus.contains("程序不存在") } && startup.allSatisfy { $0.startupStatus.contains("运行状态未知") }, "startup configuration diagnostics do not claim verified running status")
let incompleteStartup = startup.first { $0.url.lastPathComponent == "incomplete.plist" }!
expect(incompleteStartup.startupStatus.contains("缺少有效 Label") && incompleteStartup.startupStatus.contains("缺少执行程序") && incompleteStartup.repairData != nil,
       "incomplete current-user startup entries are enabled for backed-up cleanup")
let repairBackups = root.appendingPathComponent("startup-backups")
let incompleteBackup = try StartupItemRepair.quarantine(incompleteStartup, backupRoot: repairBackups, userLaunchRoot: startupRoot)
let incompleteBackupBytes = try Data(contentsOf: incompleteBackup)
let expectedIncompleteBackup = try PropertyListSerialization.data(fromPropertyList: incompleteStartupPlist, format: .xml, options: 0)
expect(incompleteBackupBytes == expectedIncompleteBackup, "one-click cleanup backs up an incomplete startup entry")
expect(!FileManager.default.fileExists(atPath: incompleteStartup.url.path), "one-click cleanup removes the incomplete entry only after backup")

var repairItem = startup.first { $0.url.lastPathComponent == "broken.plist" }!
repairItem.repairData = try Data(contentsOf: repairItem.url)
let saved = try StartupItemRepair.quarantine(repairItem, backupRoot: repairBackups, userLaunchRoot: startupRoot)
let backupBytes = try Data(contentsOf: saved)
expect(backupBytes == repairItem.repairData!, "startup repair preserves exact configuration backup")
expect(!FileManager.default.fileExists(atPath: repairItem.url.path), "startup repair removes original only after backup")
let restorationPath = try String(contentsOf: saved.deletingLastPathComponent().appendingPathComponent("original-path.txt"))
expect(restorationPath == repairItem.url.path, "startup repair records restoration path")
try Data("changed".utf8).write(to: repairItem.url)
do {
    _ = try StartupItemRepair.quarantine(repairItem, backupRoot: repairBackups, userLaunchRoot: startupRoot)
    expect(false, "changed configuration must not be removed")
} catch { expect(FileManager.default.fileExists(atPath: repairItem.url.path), "startup repair refuses changed configuration") }
try FileManager.default.removeItem(at: repairItem.url)
try FileManager.default.createSymbolicLink(at: repairItem.url, withDestinationURL: saved)
do {
    _ = try StartupItemRepair.quarantine(repairItem, backupRoot: repairBackups, userLaunchRoot: startupRoot)
    expect(false, "symlink configuration must not be removed")
} catch { expect(FileManager.default.fileExists(atPath: saved.path), "startup repair refuses symlink configuration") }

let recoveredProgram = root.appendingPathComponent("recovered-program")
try Data("restored".utf8).write(to: recoveredProgram)
try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recoveredProgram.path)
let recoveredConfig = startupRoot.appendingPathComponent("recovered.plist")
let recoveredBytes = try PropertyListSerialization.data(fromPropertyList: ["Label": "test.recovered", "Program": recoveredProgram.path], format: .xml, options: 0)
try recoveredBytes.write(to: recoveredConfig)
let recoveredItem = StartupItem(url: recoveredConfig, label: "test.recovered", program: recoveredProgram.path, kind: "测试", startupStatus: "程序不存在", repairData: recoveredBytes)
do {
    _ = try StartupItemRepair.quarantine(recoveredItem, backupRoot: repairBackups, userLaunchRoot: startupRoot)
    expect(false, "recovered executable must cancel cleanup")
} catch { expect(FileManager.default.fileExists(atPath: recoveredConfig.path), "startup repair preserves configuration when executable recovers") }

expect(DirectoryActivityMonitor.classify(UInt32(kFSEventStreamEventFlagKernelDropped)).needsRescan, "dropped directory events explicitly require a rescan")
expect(DirectoryActivityMonitor.classify(UInt32(kFSEventStreamEventFlagItemCreated)).kind == "创建", "directory events classify creation without claiming content reads")
let watchRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/.watch-" + UUID().uuidString)
try FileManager.default.createDirectory(at: watchRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: watchRoot) }
let liveDirectory = DirectoryActivityMonitor()
try liveDirectory.start(root: watchRoot)
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
let watchedFile = watchRoot.appendingPathComponent("live-watch.txt")
try Data("watched".utf8).write(to: watchedFile)
let deliveryDeadline = Date().addingTimeInterval(5)
while !liveDirectory.events.contains(where: { $0.path == watchedFile.resolvingSymlinksInPath().path }) && Date() < deliveryDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
let delivered = liveDirectory.events
liveDirectory.stop()
expect(delivered.contains { $0.path == watchedFile.resolvingSymlinksInPath().path }, "live FSEvents delivers changes within the selected directory")
let afterStop = liveDirectory.events.count
try Data("after stop".utf8).write(to: watchedFile)
RunLoop.main.run(until: Date().addingTimeInterval(0.4))
expect(liveDirectory.events.count == afterStop, "directory monitor stops delivering after shutdown")


let latestScanService = FileActivityService(scanner: { directory, _, _ in
    if directory.lastPathComponent == "old" { Thread.sleep(forTimeInterval: 0.06) }
    var result = FileScanSnapshot(); result.scannedFiles = directory.lastPathComponent == "old" ? 1 : 2
    return result
})
latestScanService.start(root: root.appendingPathComponent("old"))
latestScanService.start(root: root.appendingPathComponent("new"))
RunLoop.main.run(until: Date().addingTimeInterval(0.15))
if case let .ready(result) = latestScanService.state { expect(result.scannedFiles == 2, "older scan completion cannot replace the latest request") }
else { expect(false, "latest scan state") }
latestScanService.start(root: root.appendingPathComponent("old")); latestScanService.cancel()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
if case .cancelled = latestScanService.state { expect(true, "cancelled scan cannot publish a late result") }
else { expect(false, "cancelled scan state") }

let expiredURL = root.appendingPathComponent("expired.sqlite")
let expiredRepository = ClipboardRepository(url: expiredURL)
let expiredRecord = ClipboardRecord(capturedAt: Date().addingTimeInterval(-40 * 86400), sourceBundleID: "expired", items: [["public.utf8-plain-text": Data("old".utf8)]])
try expiredRepository.replace(with: [expiredRecord], key: key)
let expiring = ClipboardHistory(fileURL: root.appendingPathComponent("absent-legacy.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: expiredURL)
expiring.start(); expiring.stop()
let persistedExpired = try ClipboardRepository(url: expiredURL).load(key: key)
expect(persistedExpired?.isEmpty == true, "opening an entirely expired database removes old disk records after monitoring starts")

let parentPlan = FileOperationPlan.prepare(urls: [secondAction], roots: [operationRoot])
let movedRoot = root.appendingPathComponent("moved-operation")
try FileManager.default.moveItem(at: operationRoot, to: movedRoot)
try FileManager.default.createDirectory(at: operationRoot, withIntermediateDirectories: true)
try FileManager.default.linkItem(at: movedRoot.appendingPathComponent("second"), to: secondAction)
expect(!parentPlan.execute { _ in expect(false, "changed parent must not be moved"); return nil }[0].succeeded, "directory identity replacement is rejected even when file inode is preserved")
var unidentified = connections
unidentified[2].processStartTime = Date(timeIntervalSince1970: 100)
let stalePorts = NetworkObservation(connections: unidentified, sampledAt: .now, age: 1)
let recycled = MonitoredProcess(pid: 456, name: "fixture", executablePath: "/bin/sleep", cpuPercent: 0, memoryBytes: 0,
    startTime: Date(timeIntervalSince1970: 200), isProtected: false, userID: getuid())
expect(stalePorts.listeningPorts(for: [recycled]).isEmpty, "cached listening ports are not assigned to a recycled PID")


restartedHistory.record(at: historyMinute.addingTimeInterval(15), downloadBytesPerSecond: 200, uploadBytesPerSecond: 0, duration: 1)
expect(restartedHistory.snapshot(now: historyMinute.addingTimeInterval(15)).last?.bytesPerSecond == 200, "wall clock rollback discards observations from the future instead of mixing them")
let corruptHistorySuite = suite + ".corrupt-history"
let corruptHistoryDefaults = UserDefaults(suiteName: corruptHistorySuite)!
defer { corruptHistoryDefaults.removePersistentDomain(forName: corruptHistorySuite) }
let invalidPoint = NetworkHistoryPoint(timestamp: historyMinute, bytesPerSecond: 10, observedSeconds: 1e100)
corruptHistoryDefaults.set(try JSONEncoder().encode([invalidPoint]), forKey: "network.history.1h.v2")
expect(NetworkHistory(defaults: corruptHistoryDefaults, now: historyMinute.addingTimeInterval(30)).points.isEmpty, "corrupt persisted observation duration cannot reach chart integer conversion")

expect(!ClipboardHistory.isSharedInitialized, "isolated regression never initializes the production clipboard singleton")
ClipboardHistory.stopSharedIfInitialized()
expect(!ClipboardHistory.isSharedInitialized, "application shutdown does not create an unused clipboard or access Keychain")

let refreshLock = NSLock()
var refreshCount = 0
let refreshActivity = FileActivityService(scanner: { _, _, _ in
    refreshLock.lock(); refreshCount += 1; refreshLock.unlock()
    Thread.sleep(forTimeInterval: 0.03)
    return FileScanSnapshot()
})
let directoryAnalysisTest = DirectoryAnalysisController(activity: refreshActivity, delay: 0.02)
directoryAnalysisTest.start(root: root)
let refreshEvent = DirectoryActivityEvent(id: 1, date: .now, path: root.appendingPathComponent("changed").path, kind: "修改", needsRescan: false)
for _ in 0..<100 { directoryAnalysisTest.receive([refreshEvent]) }
let coalescingDeadline = Date().addingTimeInterval(5)
while Date() < coalescingDeadline {
    refreshLock.lock(); let count = refreshCount; refreshLock.unlock()
    if count >= 2, case .ready = refreshActivity.state { break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
refreshLock.lock(); let coalescedCount = refreshCount; refreshLock.unlock()
expect(coalescedCount == 2, "directory changes during a scan produce one follow-up scan without cancelling current work")
directoryAnalysisTest.receive([DirectoryActivityEvent(id: 2, date: .now, path: "/unrelated", kind: "事件丢失", needsRescan: true)])
let recoveryDeadline = Date().addingTimeInterval(5)
while Date() < recoveryDeadline {
    refreshLock.lock(); let count = refreshCount; refreshLock.unlock()
    if count >= 3, case .ready = refreshActivity.state { break }
    RunLoop.main.run(until: Date().addingTimeInterval(0.02))
}
refreshLock.lock(); let recoveredCount = refreshCount; refreshLock.unlock()
expect(recoveredCount == 3, "dropped event notification schedules a complete recovery scan")
directoryAnalysisTest.receive([refreshEvent]); directoryAnalysisTest.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
refreshLock.lock(); let stoppedCount = refreshCount; refreshLock.unlock()
expect(stoppedCount == 3 && directoryAnalysisTest.root == nil, "stopping directory analysis invalidates pending recovery work")

// Base64 of 0xff consists of '/', which JSONEncoder escapes. A valid 8 MiB
// image can therefore exceed the former 16 MiB encrypted read bound.
let expandedURL = root.appendingPathComponent("expanded-image.sqlite")
let expandedRecord = ClipboardRecord(sourceBundleID: "image.fixture",
    items: [[NSPasteboard.PasteboardType.png.rawValue: Data(repeating: 0xff, count: ClipboardHistory.maximumRecordBytes)]])
let expandedRepository = ClipboardRepository(url: expandedURL)
try expandedRepository.replace(with: [expandedRecord], key: key)
let expandedOnDisk = try Data(contentsOf: expandedURL)
expect(expandedOnDisk.count > ClipboardHistory.maximumRecordBytes * 2, "valid Base64-escaped image reproduces former read-size failure")
let expandedReopened = ClipboardRepository(url: expandedURL)
let expandedCatalog = try expandedReopened.loadCatalog(key: key)!
let expandedPage = try expandedReopened.loadPage(entries: expandedCatalog, key: key)
expect(expandedPage.count == 1 && expandedPage[0].items == expandedRecord.items,
       "reopened paged database restores a maximum-size image without rejecting encoded expansion")
let expandedFullyLoaded = try expandedReopened.load(key: key)
expect(expandedFullyLoaded?.first?.items == expandedRecord.items,
       "full migration verification accepts the same maximum-size image")
let expandedHistory = ClipboardHistory(fileURL: root.appendingPathComponent("expanded-legacy.bin"), defaults: defaults,
    pasteboard: pasteboard, keyProvider: { key }, repositoryURL: expandedURL)
expect(expandedHistory.storageError == nil && expandedHistory.records.count == 1,
       "history initialization after restart reads the expanded image")
expandedHistory.stop()

let pagedURL = root.appendingPathComponent("paged.sqlite")
let pagedRepository = ClipboardRepository(url: pagedURL)
let pageDate = Date()
let manyRecords = (0..<125).map { index in
    ClipboardRecord(capturedAt: pageDate.addingTimeInterval(-Double(index)), sourceBundleID: "paged.fixture", items: [["public.utf8-plain-text": Data("page-\(index)".utf8)]])
}
try pagedRepository.replace(with: manyRecords, key: key)
let paged = ClipboardHistory(fileURL: root.appendingPathComponent("paged-legacy.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: pagedURL)
expect(paged.records.count == 40 && paged.totalRecordCount == 125 && paged.hasMoreRecords, "opening paged history decrypts only the first 40 record bodies")
let addedPageItem = NSPasteboardItem(); addedPageItem.setString("new-page-capture", forType: .string)
paged.capture([addedPageItem], sourceBundleID: "paged.fixture")
paged.stop()
let preservedPageRecords = try ClipboardRepository(url: pagedURL).load(key: key)!
expect(preservedPageRecords.count == 126 && Set(manyRecords.map(\.id)).isSubset(of: Set(preservedPageRecords.map(\.id))), "saving a partial page retains every unloaded record")
for _ in 0..<4 { paged.loadMore(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
expect(paged.records.count == 126 && !paged.hasMoreRecords && Set(paged.records.map(\.id)).count == 126, "successive pages have stable identity without duplicates or omissions")
paged.loadMore(); paged.clear(); paged.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.05))
expect(paged.records.isEmpty && paged.totalRecordCount == 0 && !FileManager.default.fileExists(atPath: pagedURL.path), "explicit clearing removes paged history and its catalog")

let deletionURL = root.appendingPathComponent("single-deletion.sqlite")
try ClipboardRepository(url: deletionURL).replace(with: manyRecords, key: key)
let deletionHistory = ClipboardHistory(fileURL: root.appendingPathComponent("single-deletion-legacy.bin"), defaults: defaults,
    pasteboard: pasteboard, keyProvider: { key }, repositoryURL: deletionURL)
let removedVisible = deletionHistory.records[0].id
let removedUnloaded = manyRecords.last!.id
// Deletion while a page is running invalidates that page's publication.
deletionHistory.loadMore()
deletionHistory.remove(removedVisible)
deletionHistory.search("page-124")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
expect(deletionHistory.searchResults.first?.id == removedUnloaded, "single deletion still searches unloaded records")
deletionHistory.remove(removedUnloaded)
deletionHistory.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
expect(!deletionHistory.records.contains { $0.id == removedVisible } && deletionHistory.searchResults.isEmpty,
       "deleted records cannot reappear from a pending page or search")
let deletionReopened = try ClipboardRepository(url: deletionURL).load(key: key)!
expect(deletionReopened.count == 123 && !deletionReopened.contains { $0.id == removedVisible || $0.id == removedUnloaded },
       "single deletion persists across restart and preserves all other unloaded history")

let oldDatabaseURL = root.appendingPathComponent("old-schema.sqlite")
try ClipboardRepository(url: oldDatabaseURL).replace(with: manyRecords, key: key)
var oldDatabase: OpaquePointer?
expect(sqlite3_open(oldDatabaseURL.path, &oldDatabase) == SQLITE_OK, "old schema fixture opens")
expect(sqlite3_exec(oldDatabase, "DROP TABLE catalog", nil, nil, nil) == SQLITE_OK, "old schema fixture omits the new catalog")
sqlite3_close(oldDatabase)
let upgradedRepository = ClipboardRepository(url: oldDatabaseURL)
let upgradedCatalog = try upgradedRepository.loadCatalog(key: key)!
let upgradedPage = try upgradedRepository.loadPage(entries: Array(upgradedCatalog.prefix(40)), key: key)
expect(upgradedCatalog.count == 125 && upgradedPage.count == 40, "old SQLite schema upgrades to authenticated catalog without losing records")
let upgradedBytes = try Data(contentsOf: oldDatabaseURL)
expect(upgradedBytes.range(of: Data("paged.fixture".utf8)) == nil && upgradedBytes.range(of: Data("page-124".utf8)) == nil, "paged catalog introduces no plaintext source or clipboard contents")

let asyncPaged = ClipboardHistory(fileURL: root.appendingPathComponent("async-legacy.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: oldDatabaseURL, loadAsynchronously: true)
expect(asyncPaged.isLoadingHistory && asyncPaged.records.isEmpty, "asynchronous opening returns before record decryption")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
expect(!asyncPaged.isLoadingHistory && asyncPaged.records.count == 40 && asyncPaged.totalRecordCount == 125, "asynchronous first page publishes on the main run loop")
asyncPaged.loadMore(); asyncPaged.clear(); asyncPaged.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
expect(asyncPaged.records.isEmpty && asyncPaged.totalRecordCount == 0, "page completion cannot resurrect history after clear")

let retentionURL = root.appendingPathComponent("paged-retention.sqlite")
let retentionRecords = (0..<85).map { index in
    ClipboardRecord(capturedAt: Date().addingTimeInterval(index < 40 ? -Double(index) : -10 * 86400), sourceBundleID: "retention.fixture", items: [["public.utf8-plain-text": Data("retention-\(index)".utf8)]])
}
try ClipboardRepository(url: retentionURL).replace(with: retentionRecords, key: key)
let retainedHistory = ClipboardHistory(fileURL: root.appendingPathComponent("retention-legacy.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: retentionURL)
retainedHistory.start(); retainedHistory.stop()
let retentionReload = try ClipboardRepository(url: retentionURL).load(key: key)!
expect(retentionReload.count == 40 && retainedHistory.totalRecordCount == 40, "retention expires unloaded records using the complete authenticated catalog")

let clearDuringLoadURL = root.appendingPathComponent("clear-during-load.sqlite")
try ClipboardRepository(url: clearDuringLoadURL).replace(with: manyRecords, key: key)
let loadingGate = DispatchSemaphore(value: 0)
let clearDuringLoad = ClipboardHistory(fileURL: root.appendingPathComponent("clear-during-load.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { loadingGate.wait(); return key }, repositoryURL: clearDuringLoadURL, loadAsynchronously: true)
clearDuringLoad.clear(); loadingGate.signal(); clearDuringLoad.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
expect(clearDuringLoad.records.isEmpty && !clearDuringLoad.isLoadingHistory && !FileManager.default.fileExists(atPath: clearDuringLoadURL.path), "clearing during initial asynchronous load invalidates its publication")

let damagedPageURL = root.appendingPathComponent("damaged-page.sqlite")
try ClipboardRepository(url: damagedPageURL).replace(with: manyRecords, key: key)
var damagedDB: OpaquePointer?
sqlite3_open(damagedPageURL.path, &damagedDB)
let damagedID = manyRecords[40].id.uuidString
sqlite3_exec(damagedDB, "UPDATE records SET payload=zeroblob(10) WHERE id='" + damagedID + "'", nil, nil, nil)
sqlite3_close(damagedDB)
let damagedPage = ClipboardHistory(fileURL: root.appendingPathComponent("damaged-legacy.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: damagedPageURL)
damagedPage.loadMore(); damagedPage.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
expect(damagedPage.records.count == 40 && damagedPage.storageError != nil && FileManager.default.fileExists(atPath: damagedPageURL.path), "a corrupt unloaded page reports failure and preserves the database and current page")

let searchURL = root.appendingPathComponent("paged-search.sqlite")
try ClipboardRepository(url: searchURL).replace(with: manyRecords, key: key)
let searchedHistory = ClipboardHistory(fileURL: root.appendingPathComponent("search-legacy.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: searchURL)
searchedHistory.search("page-124")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
expect(searchedHistory.records.count == 40 && searchedHistory.searchResults.map(\.id) == [manyRecords[124].id], "encrypted search finds an unloaded record without expanding the visible page")
searchedHistory.search("page-")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
expect(searchedHistory.searchMatchCount == 125 && searchedHistory.searchResults.count == 100, "search counts all matches while retaining at most 100 result bodies")
searchedHistory.search("page-124"); searchedHistory.search("page-123")
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
expect(searchedHistory.searchResults.map(\.id) == [manyRecords[123].id], "new encrypted query invalidates a pending older search")
searchedHistory.search("")
expect(searchedHistory.displayedRecords.count == 40 && !searchedHistory.isSearching, "clearing the query restores the existing page without reloading all history")
searchedHistory.search("page-"); searchedHistory.clear(); searchedHistory.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
expect(searchedHistory.searchResults.isEmpty && searchedHistory.totalRecordCount == 0, "pending search cannot restore cleared records")

let featureURL = root.appendingPathComponent("clipboard-features.sqlite")
let featureText = ClipboardRecord(sourceBundleID: "text.fixture", items: [[NSPasteboard.PasteboardType.string.rawValue: Data("backup secret fixture".utf8)]])
let featureImage = ClipboardRecord(sourceBundleID: "image.fixture", items: [[NSPasteboard.PasteboardType.png.rawValue: Data("image fixture".utf8)]])
try ClipboardRepository(url: featureURL).replace(with: [featureText, featureImage], key: key)
let featureHistory = ClipboardHistory(fileURL: root.appendingPathComponent("clipboard-features.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: featureURL)
featureHistory.setFilters(sourceBundleID: "text.fixture", contentKind: "text")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
expect(featureHistory.searchResults.map(\.id) == [featureText.id], "clipboard filters combine source application and content type")
featureHistory.setFilters(sourceBundleID: "", contentKind: "")
featureHistory.updateMetadata(for: featureText.id, isPinned: true, isFavorite: true, note: "project alpha", replaceNote: true)
let clipboardBackup = try featureHistory.makeEncryptedBackup(passphrase: "backup test passphrase")
expect(clipboardBackup.range(of: Data("backup secret fixture".utf8)) == nil, "encrypted clipboard backup does not expose copied text")
let restoreURL = root.appendingPathComponent("clipboard-restore.sqlite")
try ClipboardRepository(url: restoreURL).replace(with: [ClipboardRecord(sourceBundleID: "stale.fixture", items: [[NSPasteboard.PasteboardType.string.rawValue: Data("stale".utf8)]])], key: key)
let restoredHistory = ClipboardHistory(fileURL: root.appendingPathComponent("clipboard-restore.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: { key }, repositoryURL: restoreURL)
var wrongPassphraseRejected = false
do { try restoredHistory.restoreEncryptedBackup(clipboardBackup, passphrase: "incorrect test passphrase") }
catch { wrongPassphraseRejected = true }
expect(wrongPassphraseRejected, "clipboard backup rejects an incorrect passphrase")
try restoredHistory.restoreEncryptedBackup(clipboardBackup, passphrase: "backup test passphrase")
RunLoop.main.run(until: Date().addingTimeInterval(0.2))
expect(Set(restoredHistory.records.map(\.id)) == Set([featureText.id, featureImage.id]) && restoredHistory.records.first?.isPinned == true && restoredHistory.records.first?.isFavorite == true && restoredHistory.records.first?.note == "project alpha", "clipboard backup restore replaces history and preserves pin, favorite, and note metadata")

let autoKeyURL = root.appendingPathComponent("automatic-key.sqlite")
var automaticKeyReads = 0
var keyReadOnMain = false
let automaticHistory = ClipboardHistory(fileURL: root.appendingPathComponent("automatic-key.bin"), defaults: defaults, pasteboard: pasteboard, keyProvider: {
    automaticKeyReads += 1; keyReadOnMain = keyReadOnMain || Thread.isMainThread; return key
}, repositoryURL: autoKeyURL)
let automaticFirst = NSPasteboardItem(); automaticFirst.setString("automatic-first", forType: .string)
let automaticSecond = NSPasteboardItem(); automaticSecond.setString("automatic-second", forType: .string)
automaticHistory.capture([automaticFirst], sourceBundleID: "automatic.fixture")
automaticHistory.capture([automaticSecond], sourceBundleID: "automatic.fixture")
automaticHistory.stop()
expect(automaticKeyReads == 1 && !keyReadOnMain, "capture persistence obtains its key once on the storage queue without blocking the UI")
let automaticReload = try ClipboardRepository(url: autoKeyURL).load(key: key)
expect(automaticReload?.count == 2, "automatically managed encryption preserves consecutive captures")

let catalogLock = NSLock()
var catalogScans = 0
let invalidatedCatalog = ApplicationCatalog(roots: [root], watchChanges: false, refreshDelay: 0.02, scanner: { _ in
    catalogLock.lock(); catalogScans += 1; catalogLock.unlock()
    Thread.sleep(forTimeInterval: 0.04); return []
})
invalidatedCatalog.refreshIfNeeded()
for _ in 0..<100 { invalidatedCatalog.invalidate() }
RunLoop.main.run(until: Date().addingTimeInterval(0.25))
catalogLock.lock(); let mergedScans = catalogScans; catalogLock.unlock()
expect(mergedScans == 2, "application changes during a catalog scan coalesce into one follow-up refresh")
invalidatedCatalog.invalidate(); invalidatedCatalog.stopMonitoring()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
catalogLock.lock(); let stoppedScans = catalogScans; catalogLock.unlock()
expect(stoppedScans == 2, "stopping application monitoring cancels its delayed refresh")

let liveCatalogRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("tests/.catalog-" + UUID().uuidString)
try FileManager.default.createDirectory(at: liveCatalogRoot, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: liveCatalogRoot) }
let liveCatalog = ApplicationCatalog(roots: [liveCatalogRoot], refreshDelay: 0.02)
liveCatalog.refreshIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(0.1))
let newlyInstalledApp = liveCatalogRoot.appendingPathComponent("NewFixture.app")
try FileManager.default.createDirectory(at: newlyInstalledApp, withIntermediateDirectories: true)
let catalogDeadline = Date().addingTimeInterval(5)
while liveCatalog.entries.isEmpty && Date() < catalogDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
expect(liveCatalog.entries.contains(where: { $0.url.standardizedFileURL.path == newlyInstalledApp.standardizedFileURL.path }), "live installation directory event refreshes applications before the one-minute TTL")
liveCatalog.stopMonitoring()

let sequenceTracker = AuditSequenceTracker()
expect(sequenceTracker.observe(type: 1, sequence: 5) == 0 && sequenceTracker.observe(type: 2, sequence: 99) == 0, "audit sequence baselines are independent for each event type")
expect(sequenceTracker.observe(type: 1, sequence: 8) == 2, "audit reports kernel sequence gaps before directory filtering")
expect(sequenceTracker.observe(type: 1, sequence: 0) == 0 && sequenceTracker.observe(type: 1, sequence: 1) == 0, "audit sequence reset does not underflow or invent dropped events")
let auditEntered = DispatchSemaphore(value: 0)
let auditRelease = DispatchSemaphore(value: 0)
var auditLines: [[String: Any]] = []
let auditWriter = BoundedAuditWriter(capacity: 2) { data in
    if auditLines.isEmpty { auditEntered.signal(); auditRelease.wait() }
    auditLines.append(try JSONSerialization.jsonObject(with: data) as! [String: Any])
}
auditWriter.submit(["kind": "first"])
expect(auditEntered.wait(timeout: .now() + 2) == .success, "audit output writer starts independently of the event producer")
for index in 0..<4 { auditWriter.submit(["kind": "event", "index": index]) }
auditRelease.signal(); auditWriter.flush()
expect(auditLines.count == 4 && auditLines.contains(where: { ($0["count"] as? Int) == 2 && ($0["kind"] as? String) == "output-events-dropped" }), "slow audit output keeps a bounded pending queue and emits an explicit loss count")
let failingAuditWriter = BoundedAuditWriter { _ in throw NSError(domain: "fixture", code: 1) }
failingAuditWriter.submit(["kind": "fixture"]); failingAuditWriter.flush()
expect(failingAuditWriter.outputFailed, "audit output failure stops the writer without blocking the event producer")

let indexedRoot = root.appendingPathComponent("indexed")
try FileManager.default.createDirectory(at: indexedRoot, withIntermediateDirectories: true)
let indexedA = indexedRoot.appendingPathComponent("a.png")
let indexedB = indexedRoot.appendingPathComponent("b%_.txt")
try Data(repeating: 1, count: 16384).write(to: indexedA)
try Data(repeating: 2, count: 8192).write(to: indexedB)
let directoryIndex = DirectoryIndex(directory: root.appendingPathComponent("directory-index"))
let indexInitial = directoryIndex.update(root: indexedRoot, events: nil, threshold: 0)
let indexBaseline = FileScanService.scan(root: indexedRoot, threshold: 0)
expect(indexInitial.error == nil && indexInitial.scannedFiles == indexBaseline.scannedFiles && indexInitial.largestFiles.map { $0.url.resolvingSymlinksInPath().path } == indexBaseline.largestFiles.map { $0.url.resolvingSymlinksInPath().path }, "persistent index initially matches single-pass file analysis")
try FileManager.default.removeItem(at: indexedB)
let indexDelete = directoryIndex.update(root: indexedRoot, events: [DirectoryActivityEvent(id: 42, date: .now, path: indexedB.path, kind: "删除", needsRescan: false)], threshold: 0)
expect(indexDelete.scannedFiles == 1 && indexDelete.largestFiles.first?.url.resolvingSymlinksInPath().path == indexedA.resolvingSymlinksInPath().path && !indexDelete.indexWasRebuilt, "incremental index deletes only the changed path including SQL wildcard characters")
expect(DirectoryIndex(directory: root.appendingPathComponent("directory-index")).resumeCursor(root: indexedRoot) == 42, "reopened directory index restores its committed event cursor")
let indexedC = indexedRoot.appendingPathComponent("renamed.txt")
try FileManager.default.moveItem(at: indexedA, to: indexedC)
let renameEvents = [indexedA, indexedC].map { DirectoryActivityEvent(id: 43, date: .now, path: $0.path, kind: "重命名", needsRescan: false) }
let indexRename = directoryIndex.update(root: indexedRoot, events: renameEvents, threshold: 0)
expect(indexRename.scannedFiles == 1 && indexRename.largestFiles.first?.url.resolvingSymlinksInPath().path == indexedC.resolvingSymlinksInPath().path, "incremental index updates both sides of a directory rename")
let cancelledIndexToken = ScanCancellation(); cancelledIndexToken.cancel()
let indexCancelled = directoryIndex.update(root: indexedRoot, events: [DirectoryActivityEvent(id: 44, date: .now, path: indexedC.path, kind: "修改", needsRescan: false)], cancellation: cancelledIndexToken)
expect(indexCancelled.cancelled && directoryIndex.resumeCursor(root: indexedRoot) == 43, "cancelled index transaction cannot advance the replay cursor")
let rebuildIndex = directoryIndex.update(root: indexedRoot, events: [DirectoryActivityEvent(id: 45, date: .now, path: indexedRoot.path, kind: "丢事件", needsRescan: true)], threshold: 0)
expect(rebuildIndex.indexWasRebuilt && rebuildIndex.scannedFiles == 1 && directoryIndex.resumeCursor(root: indexedRoot) == 45, "dropped events force a complete committed directory rebuild")
let oldIndexedRoot = root.appendingPathComponent("old-indexed")
try FileManager.default.moveItem(at: indexedRoot, to: oldIndexedRoot)
try FileManager.default.createDirectory(at: indexedRoot, withIntermediateDirectories: true)
try Data("replacement".utf8).write(to: indexedRoot.appendingPathComponent("fresh"))
expect(directoryIndex.resumeCursor(root: indexedRoot) == nil, "replaced root identity invalidates persisted directory replay")
let replacedIndex = directoryIndex.update(root: indexedRoot, events: [], threshold: 0)
expect(replacedIndex.indexWasRebuilt && replacedIndex.largestFiles.first?.url.lastPathComponent == "fresh", "root replacement rebuilds rows instead of reusing stale paths")



let udp = NetworkInspector.parse("p12\ncDNS\nf3\nPUDP\nn127.0.0.1:53\nf4\nPUDP\nn127.0.0.1:6000->8.8.8.8:53\nf5\nPTCP\nn*:8080\nTST=LISTEN\n")
expect(udp.count == 3 && udp[0].protocolName == "UDP" && udp[0].state == "UNCONNECTED", "UDP unconnected endpoint is not a TCP listener")
expect(udp[1].state == "CONNECTED" && udp[2].protocolName == "TCP", "protocol and state reset for every socket")
expect(NetworkObservation(connections: udp, sampledAt: .now, age: 0).listeningPorts[12] == [8080], "only TCP LISTEN supplies process listening ports")

print("\n\(checks) regression checks passed")
