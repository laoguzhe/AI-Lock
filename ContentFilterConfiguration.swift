import Foundation
import NetworkExtension
import Combine

/// Owns explicit configuration changes and read-only health monitoring.
final class ContentFilterConfiguration: ObservableObject {
    static let shared = ContentFilterConfiguration()
    static let bundleID = "com.laogu.ailock.filterprototype"
    @Published private(set) var status = "尚未查询过滤配置"
    @Published private(set) var busy = false
    @Published private(set) var enabled = false
    let health = FilterHealthMonitor()
    @Published var draft = NetworkFilterPolicy()
    init() {
        if let data = UserDefaults.standard.data(forKey: "filter.lastGoodPolicy"), let policy = try? NetworkFilterPolicy.decoded(data) { draft = policy }
        health.authorizeInstall = { [weak self] revision, done in
            guard let self, !self.busy else { done(false); return }
            self.busy = true
            self.read { result in
                self.busy = false
                guard case .success(let snapshot) = result, snapshot.enabled, snapshot.providerID == Self.bundleID,
                      let policy = try? snapshot.policy(), policy.revision == revision else { done(false); return }
                done(true)
            }
        }
        health.recover = { [weak self] revision in self?.recover(expectedRevision: revision) }
        health.verified = { policy in if AppSettings.shared.supportsWrites, let data = try? policy.encoded() { UserDefaults.standard.set(data, forKey: "filter.lastGoodPolicy") } }
    }
    private let manager = NEFilterManager.shared()
    private struct Snapshot: Equatable {
        let enabled: Bool
        let providerID: String?
        let hosts: [String]
        let description: String?
        let configuration: NEFilterProviderConfiguration?
        func policy() throws -> NetworkFilterPolicy {
            if let data = configuration?.vendorConfiguration?["policyData"] as? Data { return try NetworkFilterPolicy.decoded(data) }
            return try NetworkFilterPolicy(revision: "00000000-0000-0000-0000-000000000000", blockedHosts: hosts).validated()
        }
        static func ==(lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.enabled == rhs.enabled && lhs.providerID == rhs.providerID && lhs.hosts == rhs.hosts && lhs.description == rhs.description &&
                ContentFilterConfiguration.sameConfiguration(lhs.configuration, rhs.configuration)
        }
    }
    private static func sameConfiguration(_ lhs: NEFilterProviderConfiguration?, _ rhs: NEFilterProviderConfiguration?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.filterSockets == rhs.filterSockets && lhs.filterPackets == rhs.filterPackets &&
            lhs.filterDataProviderBundleIdentifier == rhs.filterDataProviderBundleIdentifier &&
            lhs.filterPacketProviderBundleIdentifier == rhs.filterPacketProviderBundleIdentifier &&
            lhs.serverAddress == rhs.serverAddress && lhs.username == rhs.username && lhs.organization == rhs.organization &&
            lhs.passwordReference == rhs.passwordReference && lhs.identityReference == rhs.identityReference &&
            NSDictionary(dictionary: lhs.vendorConfiguration ?? [:]).isEqual(to: rhs.vendorConfiguration ?? [:])
    }
    private func read(_ completion: @escaping (Result<Snapshot, Error>) -> Void) {
        manager.loadFromPreferences { [self] error in
            DispatchQueue.main.async {
                if let error { completion(.failure(error)); return }
                let configuration = self.manager.providerConfiguration?.copy() as? NEFilterProviderConfiguration
                completion(.success(Snapshot(enabled: self.manager.isEnabled,
                    providerID: configuration?.filterDataProviderBundleIdentifier,
                    hosts: configuration?.vendorConfiguration?["blockedHosts"] as? [String] ?? [],
                    description: self.manager.localizedDescription, configuration: configuration)))
            }
        }
    }
    func refresh() {
        guard !busy else { return }; busy = true
        read { [self] result in
            busy = false
            switch result {
            case .success(let snapshot):
                enabled = snapshot.enabled && snapshot.providerID == Self.bundleID
                if snapshot.providerID == Self.bundleID, let policy = try? snapshot.policy() {
                    draft = policy
                    if enabled { health.start(policy: policy) } else { health.stop() }
                } else { health.stop() }
                status = snapshot.configuration == nil ? "未配置过滤器" : snapshot.providerID == Self.bundleID ? (enabled ? "配置已启用；实际扩展状态请查询系统状态" : "配置已停用") : "其他应用的过滤器已配置，AI Lock 不会覆盖"
            case .failure(let error): status = "查询失败：\(error.localizedDescription)"
            }
        }
    }
    func apply(hosts: [String], enabled desiredEnabled: Bool) {
        guard !busy else { return }
        var requested = draft; requested.blockedHosts = hosts; requested.revision = UUID().uuidString
        let policy: NetworkFilterPolicy
        do { policy = try requested.validated() } catch { status = error.localizedDescription; return }
        if desiredEnabled, let error = SystemExtensionController.preflight(bundleID: Self.bundleID) { status = error; return }
        health.stop(); busy = true; status = "正在保存并复核过滤配置…"
        let transaction = FilterConfigurationTransaction<Snapshot>(read: { [self] completion in read(completion) }, save: { [self] snapshot, completion in
            manager.providerConfiguration = snapshot.configuration?.copy() as? NEFilterProviderConfiguration
            manager.localizedDescription = snapshot.description; manager.isEnabled = snapshot.enabled
            if snapshot.configuration == nil { manager.removeFromPreferences { error in DispatchQueue.main.async { completion(error) } } }
            else { manager.saveToPreferences { error in DispatchQueue.main.async { completion(error) } } }
        }, canRestore: { $0.configuration == nil || $0.providerID == Self.bundleID })
        transaction.apply(change: { snapshot in
            guard snapshot.configuration == nil || snapshot.providerID == Self.bundleID else { throw ExactHostPolicy.Failure("其他应用的过滤器已配置，未修改") }
            if !desiredEnabled { return Snapshot(enabled: false, providerID: snapshot.providerID, hosts: snapshot.hosts, description: snapshot.description, configuration: snapshot.configuration) }
            let configuration = (snapshot.configuration?.copy() as? NEFilterProviderConfiguration) ?? NEFilterProviderConfiguration()
            configuration.filterDataProviderBundleIdentifier = Self.bundleID
            configuration.filterSockets = true; configuration.filterPackets = false
            var vendor = configuration.vendorConfiguration ?? [:]; vendor["blockedHosts"] = policy.blockedHosts; vendor["policyData"] = try policy.encoded(); configuration.vendorConfiguration = vendor
            return Snapshot(enabled: desiredEnabled, providerID: Self.bundleID, hosts: policy.blockedHosts, description: "AI Lock 连接过滤", configuration: configuration)
        }, completion: { [self] result in
            busy = false
            switch result {
            case .success(let snapshot):
                enabled = snapshot.enabled
                if enabled { draft = policy; health.start(policy: policy, install: true) } else { health.stop() }
                status = snapshot.enabled ? "过滤配置已保存并复核；需系统扩展已获批准" : "过滤配置已停用并复核"
            case .failure(let error): status = error.localizedDescription; health.stop()
            }
        })
    }
    private func recover(expectedRevision: String) {
        guard !busy else { health.stop(); status = "配置操作正在进行，未执行自动恢复"; return }
        busy = true
        let transaction = FilterConfigurationTransaction<Snapshot>(read: { [self] done in read(done) }, save: { [self] snapshot, done in
            manager.providerConfiguration = snapshot.configuration; manager.localizedDescription = snapshot.description; manager.isEnabled = snapshot.enabled
            manager.saveToPreferences { error in DispatchQueue.main.async { done(error) } }
        }, canRestore: { $0.providerID == Self.bundleID && (try? $0.policy().revision) == expectedRevision })
        transaction.apply(change: { snapshot in
            guard snapshot.providerID == Self.bundleID else { throw ExactHostPolicy.Failure("配置来源已改变，未自动停用") }
            let policy = try snapshot.policy()
            guard policy.revision == expectedRevision, policy.automaticallyRecover else { throw ExactHostPolicy.Failure("规则或恢复选项已改变，未自动停用") }
            return Snapshot(enabled: false, providerID: snapshot.providerID, hosts: snapshot.hosts, description: snapshot.description, configuration: snapshot.configuration)
        }, completion: { [self] result in
            busy = false; health.stop()
            switch result {
            case .success: enabled = false; status = "过滤器持续异常，已停用并复核；规则保留，请检查后手动重新启用"
            case .failure(let error): status = "自动恢复未完成：\(error.localizedDescription)"
            }
        })
    }
}
