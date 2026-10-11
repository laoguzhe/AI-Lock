import Foundation
import Network
import AppKit
import Combine

final class FilterHealthMonitor: ObservableObject {
    @Published private(set) var status = "过滤运行状态尚未检查"
    @Published private(set) var healthy = false
    private var policy: NetworkFilterPolicy?
    private var machine = FilterHealthStateMachine()
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var path: NWPathMonitor?
    private var generation = UUID()
    private var pending: UUID?
    private var needsInstall = false
    private var reportedRevision: String?
    private var available = true
    private var sleeping = false
    private var observers: [NSObjectProtocol] = []
    var recover: ((String) -> Void)?
    var verified: ((NetworkFilterPolicy) -> Void)?
    var authorizeInstall: ((String, @escaping (Bool) -> Void) -> Void)?
    func start(policy: NetworkFilterPolicy, install: Bool = false) {
        stop(); self.policy = policy; needsInstall = install; reportedRevision = nil; available = true; sleeping = false; machine.reset(); healthy = false; status = "正在核对过滤器心跳与规则…"
        let current = generation
        let path = NWPathMonitor(); self.path = path
        path.pathUpdateHandler = { [weak self] value in DispatchQueue.main.async {
            guard let self, self.generation == current else { return }; self.available = value.status == .satisfied
        } }; path.start(queue: DispatchQueue(label: "com.laogu.ailock.filter-path"))
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in self?.sleeping = true; self?.machine.reset() })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }; self.sleeping = false; self.machine.reset(); self.closeConnection(); self.pending = nil; self.check()
        })
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.check() }; self.timer = timer; RunLoop.main.add(timer, forMode: .common)
        check()
    }
    func stop() {
        generation = UUID(); timer?.invalidate(); timer = nil; path?.cancel(); path = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }; observers = []
        closeConnection(); pending = nil; policy = nil; healthy = false; machine.reset(); status = "过滤健康监测已停止"
    }
    private func closeConnection() { connection?.invalidate(); connection = nil }
    private func check() {
        guard !sleeping, pending == nil, let policy else { return }
        guard let team = AuditIPCIdentity.team() else { status = "过滤健康监测需要有效团队签名"; return }
        if connection == nil {
            let connection = NSXPCConnection(machServiceName: team + ".com.laogu.ailock.filterprototype", options: .privileged)
            connection.remoteObjectInterface = NSXPCInterface(with: AILockFilterHealthIPC.self)
            connection.setCodeSigningRequirement(AuditIPCIdentity.requirement(bundleID: ContentFilterConfiguration.bundleID, team: team))
            connection.resume(); self.connection = connection
        }
        let current = generation, request = UUID(); pending = request
        func complete(_ data: Data?, _ failure: String?) {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == current, self.pending == request else { return }; self.pending = nil
                let snapshot = data.flatMap { $0.count <= 4096 ? (try? JSONSerialization.jsonObject(with: $0) as? [String: Any]) : nil }
                let valid = snapshot?["revision"] as? String == policy.revision && snapshot?["running"] as? Bool == true
                self.healthy = valid
                let action = self.machine.observe(healthy: valid, networkAvailable: self.available, suspended: self.sleeping, automaticallyRecover: policy.automaticallyRecover)
                if valid { self.needsInstall = false; if self.reportedRevision != policy.revision { self.reportedRevision = policy.revision; self.verified?(policy) }; self.status = self.available ? "过滤器运行正常，规则版本已核对" : "过滤器心跳正常；当前网络不可用" }
                else {
                    self.closeConnection()
                    self.status = self.available ? "过滤器心跳异常（\(self.machine.failures)/3）：\(failure ?? "规则版本不一致")" : "当前网络不可用；暂不自动停用过滤"
                    if action == .disableFilter { self.status = "过滤器连续异常，正在停用本应用过滤配置…"; self.recover?(policy.revision) }
                }
            }
        }
        guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ complete(nil, $0.localizedDescription) }) as? AILockFilterHealthIPC else { complete(nil, "健康服务不可用"); return }
        if needsInstall {
            guard let authorizeInstall else { complete(nil, "未能核对当前配置"); return }
            authorizeInstall(policy.revision) { [weak self] allowed in
                guard let self, self.generation == current, self.pending == request else { return }
                guard allowed else { complete(nil, "配置已改变或正在操作，未更新运行中的规则"); return }
                do { proxy.install(policy: try policy.encoded(), reply: complete) } catch { complete(nil, error.localizedDescription) }
            }
        }
        else { proxy.heartbeat(revision: policy.revision, reply: complete) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.generation == current, self.pending == request else { return }; complete(nil, "心跳超时")
        }
    }
    deinit {
        timer?.invalidate(); path?.cancel(); connection?.invalidate()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
