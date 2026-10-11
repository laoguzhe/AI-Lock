import XCTest
@testable import AILockCore

final class CoreTests: XCTestCase {
    func testAuditIdentitySurvivesHistoryRoundtripAndReplay() throws {
        let id = UUID()
        let payload: [String: Any] = ["eventID": id.uuidString, "kind": "rename", "path": "/tmp/file", "destinationPath": "/Users/test/.ssh/key", "executable": "/Applications/Claude.app/Contents/MacOS/helper", "pid": 123, "receivedAt": Date().timeIntervalSince1970, "signingID": "com.anthropic.claude"]
        let record = try XCTUnwrap(FileAuditRecord(payload))
        let restored = try JSONDecoder().decode(FileAuditRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.id, id)
        XCTAssertEqual(FileAuditRecord(payload)?.id, id)
        XCTAssertEqual(restored.application, "Claude")
        XCTAssertTrue(restored.isAI)
        XCTAssertEqual(restored.sensitiveReason, "密钥目录")
        XCTAssertEqual(restored.processMetadata["signingID"], "com.anthropic.claude")
    }
    func testAuditExplainsEvidenceWithoutClaimingReadOrUpload() throws {
        let payload: [String: Any] = ["kind": "open", "path": "/tmp/ordinary", "executable": "/usr/bin/python3", "pid": 321, "receivedAt": 100.0, "parentPID": 123]
        let record = try XCTUnwrap(FileAuditRecord(payload))
        XCTAssertFalse(record.isAI, "A parent PID alone must not imply AI ownership")
        XCTAssertNil(record.sensitiveReason)
        XCTAssertTrue(record.explanation.contains("不能证明上传"))
        XCTAssertNil(FileAuditRecord(["kind": "open", "path": "/tmp/file"]))
    }

    func testSensitivePathsAndFalsePositiveBoundaries() {
        for path in ["/Users/test/.git-credentials", "/Users/test/.config/gcloud/application_default_credentials.json",
                     "/Users/test/.kube/config", "/Users/test/.docker/config.json",
                     "/Users/test/Library/Application Support/Google/Chrome/Default/Network/Cookies-wal",
                     "/Users/test/Library/Application Support/Firefox/Profiles/test/logins.json",
                     "/Users/test/Library/Safari/History.db"] {
            XCTAssertNotNil(AuditPathRules.sensitiveReason(path: path), path)
        }
        for path in ["/tmp/Cookies", "/tmp/.ssh-backup/readme", "/tmp/.config/gcloudish/config", "/tmp/environment.txt"] {
            XCTAssertNil(AuditPathRules.sensitiveReason(path: path), path)
        }
        XCTAssertNotNil(AuditPathRules.sensitiveReason(path: "/tmp/ordinary", destination: "/Users/test/.ssh/new-key"))
        XCTAssertNotNil(AuditPathRules.sensitiveReason(path: "/tmp/.env.production"))
    }
    func testSettingsMigrationKeepsStableIdentifiers() {
        let suite = "ailock.core-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["文件活动": 3, "应用日志": 8], forKey: "overview.hotkeys")
        defaults.set("⌃ Space", forKey: "search.hotkey")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.moduleHotkeys, ["files": 3, "logs": 8])
        XCTAssertEqual(settings.searchHotkey, .controlSpace)
        settings.moduleHotkeys = ["network": 4]
        XCTAssertEqual(AppSettings(defaults: defaults).moduleHotkeys, ["network": 4])
        XCTAssertEqual(defaults.dictionary(forKey: "overview.hotkeys") as? [String: Int], ["网络活动": 4])
    }
    func testSettingsValidationAndFutureSchema() {
        let suite = "ailock.core-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        var invalid = AlertThresholds(); invalid.cpu = .nan
        XCTAssertFalse(settings.saveAlerts(invalid))
        XCTAssertEqual(settings.alerts, AlertThresholds())
        settings.clipboardRetentionDays = 999; XCTAssertEqual(settings.clipboardRetentionDays, 30)
        settings.clipboardExcludedBundleIDs = ["x", "", "x"]; XCTAssertEqual(settings.clipboardExcludedBundleIDs, ["x"])
        defaults.set(99, forKey: "ailock.settings.schemaVersion")
        let future = AppSettings(defaults: defaults)
        future.clipboardRetentionDays = 1
        XCTAssertEqual(future.clipboardRetentionDays, 30)
        XCTAssertEqual(defaults.integer(forKey: "ailock.settings.schemaVersion"), 99)
    }
    func testSequenceTypesAndWrap() {
        let tracker = AuditSequenceTracker()
        XCTAssertEqual(tracker.observe(type: 1, sequence: 5), 0)
        XCTAssertEqual(tracker.observe(type: 2, sequence: 50), 0)
        XCTAssertEqual(tracker.observe(type: 1, sequence: 8), 2)
        XCTAssertEqual(tracker.observe(type: 1, sequence: 0), 0)
    }
    func testIndexTransactionAndReplayIdentity() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let watched = root.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = watched.appendingPathComponent("test.txt")
        try Data("test".utf8).write(to: file)
        let index = DirectoryIndex(directory: root.appendingPathComponent("index"))
        let initial = index.update(root: watched, events: nil, threshold: 0)
        XCTAssertNil(initial.error); XCTAssertEqual(initial.scannedFiles, 1)
        let event = DirectoryActivityEvent(id: 10, date: .now, path: file.path, kind: "修改", needsRescan: false)
        XCTAssertNil(index.update(root: watched, events: [event]).error)
        XCTAssertEqual(index.resumeCursor(root: watched), 10)
        let cancelled = ScanCancellation(); cancelled.cancel()
        XCTAssertTrue(index.update(root: watched, events: nil, cancellation: cancelled).cancelled)
        XCTAssertEqual(index.resumeCursor(root: watched), 10)
        try FileManager.default.removeItem(at: file)
        XCTAssertEqual(index.update(root: watched, events: [event], threshold: 0).scannedFiles, 0)
    }

    func testExactHostPolicyRejectsBroadRules() throws {
        XCTAssertEqual(try ExactHostPolicy([" EXAMPLE.COM ", "example.com", "::1"]).hosts, ["::1", "example.com"])
        for value in ["*", "https://example.com", "example.com:443/path", "host name", "", "example.com:443", ":", "a..b", "-bad.com"] {
            XCTAssertThrowsError(try ExactHostPolicy([value]))
        }
        XCTAssertThrowsError(try ExactHostPolicy(Array(repeating: "host", count: 257)))
        XCTAssertEqual(try ExactHostPolicy([]).hosts, [])
        XCTAssertEqual(try ExactHostPolicy(["0:0:0:0:0:0:0:1", "EXAMPLE.COM."]).hosts, ["::1", "example.com"])
    }
    func testFilterSaveReadbackAndRollback() {
        var stored = 1
        var saved: [Int] = []
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.success(stored)) }, save: { value, done in stored = value; saved.append(value); done(nil) })
        var result: Result<Int, Error>?
        transaction.apply(change: { $0 + 1 }) { result = $0 }
        XCTAssertEqual(try? result?.get(), 2)
        XCTAssertEqual(saved, [2])
    }
    func testFilterReadbackMismatchRestoresOriginal() {
        var stored = 1; var saves = 0
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.success(stored)) }, save: { value, done in saves += 1; stored = saves == 1 ? 99 : value; done(nil) })
        var message = ""
        transaction.apply(change: { $0 + 1 }) { if case .failure(let error) = $0 { message = error.localizedDescription } }
        XCTAssertEqual(stored, 1); XCTAssertEqual(saves, 2)
        XCTAssertTrue(message.contains("已恢复原配置"))
    }
    func testFilterRollbackFailureIsVisible() {
        var saves = 0; var message = ""; var stored = 1
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.success(stored)) }, save: { value, done in saves += 1; if saves == 1 { stored = value }; done(ExactHostPolicy.Failure("注入保存失败")) })
        transaction.apply(change: { $0 + 1 }) { if case .failure(let error) = $0 { message = error.localizedDescription } }
        XCTAssertEqual(saves, 2); XCTAssertTrue(message.contains("回滚失败"))
    }
    func testRejectedFilterChangeDoesNotSave() {
        var saves = 0
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.success(1)) }, save: { _, done in saves += 1; done(nil) })
        transaction.apply(change: { _ in throw ExactHostPolicy.Failure("外部配置") }) { _ in }
        XCTAssertEqual(saves, 0)
    }
    func testFailedInitialFilterReadDoesNotSave() {
        var saves = 0
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.failure(ExactHostPolicy.Failure("读取失败"))) }, save: { _, done in saves += 1; done(nil) })
        transaction.apply(change: { $0 + 1 }) { _ in }
        XCTAssertEqual(saves, 0)
    }

    func testIndexDoesNotKeepFileReplacedWithExternalSymlink() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let file = root.appendingPathComponent("file.txt"), outside = base.appendingPathComponent("outside.txt")
        try Data([1]).write(to: file); try Data([2]).write(to: outside)
        let index = DirectoryIndex(directory: base.appendingPathComponent("index"))
        XCTAssertEqual(index.update(root: root, events: nil, threshold: 0).scannedFiles, 1)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        let result = index.update(root: root, events: [DirectoryActivityEvent(id: 20, date: .now, path: file.path, kind: "修改", needsRescan: false)], threshold: 0)
        XCTAssertNil(result.error); XCTAssertEqual(result.scannedFiles, 0)
        XCTAssertEqual(index.resumeCursor(root: root), 20)
    }

    func testModuleVisibilityOrderAndFontMigration() {
        let suite = "ailock.core-tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(1, forKey: "ailock.settings.schemaVersion")
        defaults.set("应用日志,文件活动,应用日志", forKey: "overview.visibleModules")
        defaults.set("文件活动,网络活动", forKey: "overview.moduleOrder")
        defaults.set(13.0, forKey: "overview.fontSize")
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.visibleModuleIDs, ["logs", "files"])
        XCTAssertEqual(settings.orderedModuleIDs, ["files", "network"])
        XCTAssertEqual(settings.fontScale, 1)
        settings.visibleModuleIDs = []
        XCTAssertEqual(AppSettings(defaults: defaults).visibleModuleIDs, [])
        XCTAssertEqual(defaults.string(forKey: "overview.visibleModules.v1"), "__none__")
        XCTAssertEqual(defaults.integer(forKey: "ailock.settings.schemaVersion"), 2)
    }

    func testAuditDeliveryWindowBoundsAndLoss() throws {
        let buffer = AuditEventBuffer(capacity: 3)
        for index in 1...5 { buffer.append(["kind": "open", "path": String(index)]) }
        let first = try JSONSerialization.jsonObject(with: buffer.snapshot(after: 0, limit: 2)) as! [String: Any]
        XCTAssertEqual(first["deliveryGap"] as? String, "2")
        XCTAssertEqual(first["cursor"] as? String, "4")
        XCTAssertEqual((first["events"] as? [[String: Any]])?.count, 2)
        let second = try JSONSerialization.jsonObject(with: buffer.snapshot(after: 4)) as! [String: Any]
        XCTAssertEqual(second["deliveryGap"] as? String, "0")
        XCTAssertEqual(second["cursor"] as? String, "5")
        buffer.clear()
        let reset = try JSONSerialization.jsonObject(with: buffer.snapshot(after: 5)) as! [String: Any]
        XCTAssertEqual(reset["reset"] as? Bool, true)
        XCTAssertEqual(reset["cursor"] as? String, "0")
    }

    func testRejectedFilterSaveDoesNotRewriteUnchangedOriginal() {
        var saves = 0; var message = ""
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.success(1)) }, save: { _, done in saves += 1; done(ExactHostPolicy.Failure("拒绝授权")) })
        transaction.apply(change: { $0 + 1 }) { if case .failure(let error) = $0 { message = error.localizedDescription } }
        XCTAssertEqual(saves, 1); XCTAssertTrue(message.contains("原配置未改变"))
    }
    func testRollbackDoesNotOverwriteForeignConfiguration() {
        var stored = 1; var saves = 0; var message = ""
        let transaction = FilterConfigurationTransaction<Int>(read: { $0(.success(stored)) }, save: { _, done in stored = 99; saves += 1; done(nil) }, canRestore: { $0 != 99 })
        transaction.apply(change: { $0 + 1 }) { if case .failure(let error) = $0 { message = error.localizedDescription } }
        XCTAssertEqual(saves, 1); XCTAssertEqual(stored, 99); XCTAssertTrue(message.contains("其他来源改变"))
    }
}
