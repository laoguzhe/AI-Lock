import Foundation

final class TestService: NSObject, AILockAuditIPC {
    let buffer = AuditEventBuffer(capacity: 3)
    func configure(root: String?, reply: @escaping (Bool, String) -> Void) { buffer.clear(); reply(true, root ?? "stopped") }
    func fetch(after cursor: String, reply: @escaping (Data?, String?) -> Void) {
        do { reply(try buffer.snapshot(after: UInt64(cursor) ?? 0), nil) } catch { reply(nil, error.localizedDescription) }
    }
}
final class TestListener: NSObject, NSXPCListenerDelegate {
    let service = TestService()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AILockAuditIPC.self)
        connection.exportedObject = service; connection.resume(); return true
    }
}
precondition(NSStringFromProtocol(AILockAuditIPC.self) == "AILockAuditIPC", "IPC protocol needs a stable Objective-C name across targets")
let delegate = TestListener()
let listener = NSXPCListener.anonymous(); listener.delegate = delegate; listener.resume()
let connection = NSXPCConnection(listenerEndpoint: listener.endpoint)
connection.remoteObjectInterface = NSXPCInterface(with: AILockAuditIPC.self); connection.resume()
defer { connection.invalidate(); listener.invalidate() }
let proxy = connection.remoteObjectProxyWithErrorHandler { fputs("IPC error: \($0)\n", stderr); exit(1) } as! AILockAuditIPC
func check(_ name: String, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(5)
    while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    guard condition() else { fputs("FAIL: " + name + "\n", stderr); exit(1) }
    print("PASS: " + name)
}
var configured = false
proxy.configure(root: "/isolated-fixture") { ok, value in DispatchQueue.main.async { configured = ok && value == "/isolated-fixture" } }
check("audit root configuration crosses NSXPC transport") { configured }
delegate.service.buffer.append(["kind": "rename", "path": "/isolated-fixture/a", "destinationPath": "/isolated-fixture/b"])
var delivered = false
proxy.fetch(after: "0") { data, error in DispatchQueue.main.async {
    let payload = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    delivered = error == nil && payload?["cursor"] as? String == "1" && (payload?["events"] as? [[String: Any]])?.first?["destinationPath"] as? String == "/isolated-fixture/b"
} }
check("bounded event data crosses NSXPC transport") { delivered }
var stopped = false
proxy.configure(root: nil) { ok, value in DispatchQueue.main.async { stopped = ok && value == "stopped" } }
check("nil root stops and clears a session through NSXPC") { stopped }

final class HealthFixture: NSObject, AILockFilterHealthIPC {
    var revision = ""
    func install(policy: Data, reply: @escaping (Data?, String?) -> Void) {
        revision = String(data: policy, encoding: .utf8) ?? ""
        reply(Data(revision.utf8), nil)
    }
    func heartbeat(revision: String, reply: @escaping (Data?, String?) -> Void) {
        if revision == self.revision { reply(Data(revision.utf8), nil) }
        else { reply(nil, "revision mismatch") }
    }
}
final class HealthListener: NSObject, NSXPCListenerDelegate {
    let service = HealthFixture()
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: AILockFilterHealthIPC.self)
        connection.exportedObject = service; connection.resume(); return true
    }
}
precondition(NSStringFromProtocol(AILockFilterHealthIPC.self) == "AILockFilterHealthIPC")
let healthDelegate = HealthListener(), healthListener = NSXPCListener.anonymous()
healthListener.delegate = healthDelegate; healthListener.resume()
let healthConnection = NSXPCConnection(listenerEndpoint: healthListener.endpoint)
healthConnection.remoteObjectInterface = NSXPCInterface(with: AILockFilterHealthIPC.self); healthConnection.resume()
defer { healthConnection.invalidate(); healthListener.invalidate() }
let healthProxy = healthConnection.remoteObjectProxyWithErrorHandler { fputs("Health IPC error: \($0)\n", stderr); exit(1) } as! AILockFilterHealthIPC
var installed = false
healthProxy.install(policy: Data("fixture-revision".utf8)) { data, error in DispatchQueue.main.async {
    installed = error == nil && data == Data("fixture-revision".utf8)
} }
check("filter rule data crosses NSXPC transport") { installed }
var matched = false
healthProxy.heartbeat(revision: "fixture-revision") { data, error in DispatchQueue.main.async { matched = error == nil && data != nil } }
check("filter heartbeat revision crosses NSXPC transport") { matched }
var rejected = false
healthProxy.heartbeat(revision: "stale-revision") { data, error in DispatchQueue.main.async { rejected = data == nil && error == "revision mismatch" } }
check("stale filter revision returns an explicit IPC error") { rejected }
