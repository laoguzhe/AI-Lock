import Foundation

func connection(_ id: String = "socket", state: String = "ESTABLISHED", start: TimeInterval = 1, remote: String = "8.8.8.8:443") -> NetworkConnection {
    NetworkConnection(id: id, pid: 42, process: "Example", protocolName: "TCP", local: "127.0.0.1:5000", remote: remote, state: state, processStartTime: Date(timeIntervalSince1970: start))
}
var passed = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }; passed += 1
}
var history = NetworkActivityHistory()
let t = Date(timeIntervalSince1970: 1000)
history.ingest([connection()], at: t)
check(history.records.count == 1 && history.records[0].baseline, "First snapshot must be a baseline, not a new connection")
let identity = history.records[0].id
history.ingest([connection(state: "CLOSE_WAIT"), connection("second")], at: t.addingTimeInterval(5))
check(history.records.first { $0.id == identity }?.changes.count == 2, "State transitions must be retained")
check(history.records.filter { !$0.baseline }.count == 1, "New sockets must be distinguished from baseline")
history.ingest([connection("second")], at: t.addingTimeInterval(10))
check(history.records.first { $0.id == identity }?.endedAt == t.addingTimeInterval(10), "Missing socket must end")
check(history.records.first { $0.id == identity }?.lastSeen == t.addingTimeInterval(5), "Last seen must not claim unobserved time")
history.ingest([connection(), connection("second")], at: t.addingTimeInterval(15))
check(history.records.filter { $0.connection.id == "socket" }.count == 2, "Reopened socket must start a new historical session")
history.interrupt()
history.ingest([connection("third")], at: t.addingTimeInterval(20))
check(history.records.first { $0.connection.id == "third" }?.baseline == true, "Resume must not invent new connection events during a gap")
check(history.records.contains { $0.changes.last?.contains("结束时间未知") == true }, "Sampling gaps must be explicit")
var reused = NetworkActivityHistory()
reused.ingest([connection()], at: t)
reused.ingest([connection(start: 2)], at: t.addingTimeInterval(5))
check(reused.records.count == 2 && reused.records.filter(\.active).count == 1, "PID reuse must not merge different processes")
var capped = NetworkActivityHistory()
capped.ingest((0..<1100).map { connection("old\($0)") }, at: t)
capped.ingest([connection("live")], at: t.addingTimeInterval(5))
check(capped.records.count == 1001 && capped.records.contains { $0.active && $0.connection.id == "live" }, "History cap must preserve every live socket")
for (remote, scope) in [("[::1]:443", "本机"), ("127.0.0.8:80", "本机"), ("172.16.1.2:443", "局域网"), ("172.32.1.2:443", "外网"), ("[fd12::1]:53", "局域网"), ("[fe80::1%en0]:5353", "局域网"), ("8.8.8.8:53", "外网"), ("*", "未连接")] {
    check(NetworkEndpoint.scope(connection(remote: remote)) == scope, "Incorrect scope for \(remote)")
}
check(NetworkEndpoint.scope(connection(state: "LISTEN", remote: "*")) == "监听", "Listener classification")
check(NetworkEndpoint.host("[2001:db8::1]:443") == "2001:db8::1", "IPv6 endpoint splitting")
check(NetworkEndpoint.service(connection(remote: "8.8.8.8:53")) == "DNS", "Known service label")
let model = NetworkActivityModel()
let now = Date()
model.history.ingest([connection("first"), connection("dns", remote: "8.8.8.8:53")], at: now.addingTimeInterval(-40))
model.history.ingest([connection("first", state: "CLOSE_WAIT")], at: now)
model.period = "最近变化"
check(model.visible.count == 2, "Recent changes must include state transitions and endings")
model.search = "DNS"
check(model.visible.count == 1 && model.visible[0].connection.id == "dns", "Search must include service labels and ended connections")
model.proto = "UDP"
check(model.visible.isEmpty, "Filters must combine rather than override each other")
model.proto = "所有协议"; model.search = ""; model.period = "当前连接"
check(model.visible.count == 2, "Just ended sockets must remain briefly visible")
// Use a separate consistent timeline for the ended-row timeout.
let expired = NetworkActivityModel()
expired.history.ingest([connection()], at: now.addingTimeInterval(-50))
expired.history.ingest([], at: now.addingTimeInterval(-35))
check(expired.visible.isEmpty, "Ended rows must auto-hide after 30 seconds")
expired.period = "全部记录"
check(expired.visible.count == 1, "Hidden ended rows must remain available in history")
model.period = "全部记录"; model.selected = model.all[0].id; model.search = "not-present"
check(model.chosen == nil, "Hidden selections must not remain actionable")
model.search = ""; model.rates = [42: (down: 100, up: 20)]
let live = NetworkActivityModel()
live.history.ingest([connection("a"), connection("b")], at: now)
live.rates = [42: (down: 100, up: 20)]
check(live.rate(for: live.all)?.down == 100, "App flow must count a PID once, regardless of socket count")
check(NetworkActivityModel.speed(0) == "0 B/s", "Zero flow must remain readable")
var exportRecord = live.all[0]
exportRecord.connection = NetworkConnection(id: "csv", pid: 42, process: "=formula,\"quoted\"", protocolName: "TCP", local: "*:80", remote: "8.8.8.8:443", state: "ESTABLISHED")
let csv = NetworkActivityModel.csv([exportRecord])
check(csv.hasPrefix("\u{FEFF}"), "CSV must preserve Chinese text for spreadsheet readers")
check(csv.contains("'="), "CSV must neutralize formula-like application names")
check(csv.contains("\"\"quoted\"\""), "CSV must escape embedded quotes")
check(csv.components(separatedBy: "\r\n").count == 2, "Export must contain the header and selected filtered rows")
check(NetworkEndpoint.scope(connection(remote: "[ff02::fb]:5353")) == "多播", "mDNS must not be labeled as Internet traffic")
print("Network activity: \(passed) checks passed")
