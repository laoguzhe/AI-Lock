import Foundation
struct Fixture: Codable { let events: [FileAuditRecord]; let gaps: [String]; let reviewed: Set<UUID> }
let root = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-audit-test-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let url = root.appendingPathComponent("history.json")
func record(_ age: Double) -> FileAuditRecord {
    FileAuditRecord(["eventID": UUID().uuidString, "kind": "open", "path": "/Users/test/.ssh/id_ed25519", "executable": "/Applications/Claude.app/Contents/MacOS/Claude", "receivedAt": Date().addingTimeInterval(-age).timeIntervalSince1970, "pid": 42])!
}
let recent = record(60), old = record(8 * 86400)
try JSONEncoder().encode(Fixture(events: [recent, old], gaps: ["fixture gap"], reviewed: [old.id])).write(to: url)
let client = AuditExtensionClient(historyURL: url)
precondition(client.events.count == 1 && client.events[0].id == recent.id)
precondition(client.reviewed.isEmpty && client.gaps == ["fixture gap"])
client.markReviewed(recent)
func waitFor(_ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(condition())
}
waitFor { (try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).reviewed.contains(recent.id)) == true }
let restored = AuditExtensionClient(historyURL: url)
precondition(restored.reviewed.contains(recent.id) && restored.events[0].id == recent.id)
let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
precondition(permissions.intValue == 0o600)
client.clearHistory()
waitFor { (try? JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).events.isEmpty) == true }
precondition(AuditExtensionClient(historyURL: url).events.isEmpty)
try Data("broken".utf8).write(to: url)
precondition(AuditExtensionClient(historyURL: url).historyStatus.contains("加载失败"))
let impossible = root.appendingPathComponent("not-a-directory")
try Data().write(to: impossible)
let failure = AuditExtensionClient(historyURL: impossible.appendingPathComponent("history.json"))
failure.clearHistory()
waitFor { failure.historyStatus.contains("保存失败") }
print("PASS: retention, review restore, private permissions, clear history, corrupt data and write failure")
