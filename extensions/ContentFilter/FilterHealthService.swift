import Foundation

final class FilterHealthService: NSObject, NSXPCListenerDelegate, AILockFilterHealthIPC {
    private let listener: NSXPCListener
    private let lock = NSLock()
    private var policy: NetworkFilterPolicy
    private var lease: FilterRecoveryLease
    private let instance = UUID().uuidString
    private let timer: DispatchSourceTimer
    private var connections: [UUID: NSXPCConnection] = [:]
    private var running = true
    init(policy: NetworkFilterPolicy, team: String, serviceName: String) {
        self.policy = policy; lease = FilterRecoveryLease(now: ProcessInfo.processInfo.systemUptime, automaticallyRecover: policy.automaticallyRecover)
        listener = NSXPCListener(machServiceName: serviceName)
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.laogu.ailock.filter-lease"))
        super.init(); listener.delegate = self
        listener.setConnectionCodeSigningRequirement(AuditIPCIdentity.requirement(bundleID: "com.laogu.ailock", team: team))
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in guard let self else { return }; self.lock.lock(); _ = self.lease.shouldBypass(now: ProcessInfo.processInfo.systemUptime); self.lock.unlock() }
        listener.resume(); timer.resume()
    }
    func stop() {
        lock.lock(); running = false; let existing = Array(connections.values); connections = [:]; lock.unlock()
        timer.cancel(); listener.invalidate(); existing.forEach { $0.invalidate() }
    }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        lock.lock(); guard running, connections.count < 8 else { lock.unlock(); return false }
        let id = UUID(); connections[id] = connection; lock.unlock()
        connection.exportedInterface = NSXPCInterface(with: AILockFilterHealthIPC.self); connection.exportedObject = self
        connection.invalidationHandler = { [weak self] in guard let self else { return }; self.lock.lock(); self.connections.removeValue(forKey: id); self.lock.unlock() }
        connection.interruptionHandler = { [weak connection] in connection?.invalidate() }
        connection.resume(); return true
    }
    func install(policy data: Data, reply: @escaping (Data?, String?) -> Void) {
        do {
            let next = try NetworkFilterPolicy.decoded(data)
            lock.lock()
            guard running else { lock.unlock(); reply(nil, "过滤器已停止"); return }
            policy = next; lease = FilterRecoveryLease(now: ProcessInfo.processInfo.systemUptime, automaticallyRecover: next.automaticallyRecover)
            let data = try? snapshot(); lock.unlock(); reply(data, nil)
        } catch { reply(nil, error.localizedDescription) }
    }
    func heartbeat(revision: String, reply: @escaping (Data?, String?) -> Void) {
        lock.lock()
        guard running, revision == policy.revision else { lock.unlock(); reply(nil, "过滤规则版本不一致或过滤器已停止"); return }
        lease.renew(now: ProcessInfo.processInfo.systemUptime)
        let data = try? snapshot(); lock.unlock(); reply(data, nil)
    }
    private func snapshot() throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "revision": policy.revision, "instance": instance, "running": running, "automaticallyRecover": policy.automaticallyRecover])
    }
    func decision(host: String?, auditToken: Data?) -> Bool {
        lock.lock(); let rules = policy; let bypass = !running || lease.shouldBypass(now: ProcessInfo.processInfo.systemUptime); lock.unlock()
        if bypass { return false }
        if let host, rules.blockedHosts.contains(host) { return true }
        guard rules.applications.contains(where: { $0.host == nil || $0.host == host }) else { return false }
        return rules.blocks(host: host, application: SignedApplicationResolver.flowApplication(auditToken: auditToken))
    }
    deinit { timer.cancel(); listener.invalidate() }
}
