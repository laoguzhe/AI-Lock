import Foundation
import EndpointSecurity

final class AuditIPCSession: NSObject, AILockAuditIPC {
    weak var service: AuditIPCService?
    let events = AuditEventBuffer()
    fileprivate var root: String?
    fileprivate var generation = UUID()
    func configure(root: String?, reply: @escaping (Bool, String) -> Void) { service?.configure(self, root: root, reply: reply) }
    func fetch(after cursor: String, reply: @escaping (Data?, String?) -> Void) {
        guard let cursor = UInt64(cursor) else { reply(nil, "事件游标无效"); return }
        do { reply(try events.snapshot(after: cursor), nil) } catch { reply(nil, error.localizedDescription) }
    }
}

/// NOTIFY only. Signed host connections own independent roots and bounded in-memory windows.
final class AuditIPCService: NSObject, NSXPCListenerDelegate {
    private let listener: NSXPCListener
    private let team: String
    private let queue = DispatchQueue(label: "com.laogu.ailock.audit-configuration")
    private let lock = NSLock()
    private var sessions: [UUID: AuditIPCSession] = [:]
    private var client: OpaquePointer?
    init(team: String, serviceName: String) { self.team = team; listener = NSXPCListener(machServiceName: serviceName); super.init(); listener.delegate = self }
    func start() { listener.resume() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock()
        guard sessions.count < 16 else { lock.unlock(); return false }
        let id = UUID(), session = AuditIPCSession(); session.service = self; sessions[id] = session
        lock.unlock()
        connection.setCodeSigningRequirement(AuditIPCIdentity.requirement(bundleID: "com.laogu.ailock", team: team))
        connection.exportedInterface = NSXPCInterface(with: AILockAuditIPC.self); connection.exportedObject = session
        connection.invalidationHandler = { [weak self] in self?.queue.async { [weak self] in
            guard let self else { return }; self.lock.lock(); self.sessions.removeValue(forKey: id); self.lock.unlock(); self.stopIfUnused()
        } }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume(); return true
    }
    func configure(_ session: AuditIPCSession, root input: String?, reply: @escaping (Bool, String) -> Void) {
        queue.async { [self] in
            let root: String?
            if let input {
                guard input.hasPrefix("/"), input.utf8.count <= 4096 else { reply(false, "请选择绝对目录"); return }
                let url = FilesystemPath.canonical(URL(fileURLWithPath: input))
                guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]), values.isDirectory == true else { reply(false, "目录不可访问"); return }
                root = url.path
            } else { root = nil }
            lock.lock()
            let active = sessions.values.filter { $0.root != nil && $0 !== session }.count
            let registered = sessions.values.contains { $0 === session }
            lock.unlock()
            guard registered else { reply(false, "连接已失效"); return }
            guard root == nil || active < 4 else { reply(false, "最多 4 个活动审计会话"); return }
            if root != nil, client == nil {
                let tracker = AuditSequenceTracker()
                var created: OpaquePointer?
                let result = es_new_client(&created) { [weak self] _, message in
                    guard let self else { return }
                    let msg = message.pointee
                    let gap = msg.version >= 2 ? tracker.observe(type: msg.event_type.rawValue, sequence: msg.seq_num) : 0
                    guard let event = auditEvent(message) else { return }
                    self.lock.lock(); let targets = self.sessions.compactMap { id, session -> (UUID, AuditIPCSession, String, UUID)? in session.root.map { (id, session, $0, session.generation) } }; self.lock.unlock()
                    for (id, session, root, generation) in targets {
                        self.lock.lock(); defer { self.lock.unlock() }
                        guard self.sessions[id] === session, session.generation == generation else { continue }
                        if gap > 0 { session.events.append(["kind": "kernel-events-dropped", "eventType": msg.event_type.rawValue, "count": String(gap)]) }
                        if auditEventMatches(event, root: root) { session.events.append(event) }
                    }
                }
                guard result == ES_NEW_CLIENT_RESULT_SUCCESS, let created else { reply(false, "ES 客户端创建失败：\(result.rawValue)；未开始采集"); return }
                var types = auditEventTypes
                guard es_subscribe(created, &types, UInt32(types.count)) == ES_RETURN_SUCCESS else { es_delete_client(created); reply(false, "ES 订阅失败；未开始采集"); return }
                client = created
            }
            lock.lock(); session.events.clear(); session.generation = UUID(); session.root = root; lock.unlock()
            stopIfUnused(); reply(true, root == nil ? "已停止采集" : "已配置目录；NOTIFY 元数据审计已开始")
        }
    }
    private func stopIfUnused() {
        lock.lock(); let active = sessions.values.contains { $0.root != nil }; lock.unlock()
        if !active, let client { es_delete_client(client); self.client = nil }
    }
}
