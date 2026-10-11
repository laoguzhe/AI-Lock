import Foundation
import NetworkExtension
import OSLog
import Darwin

@objc(AILockFilterDataProvider)
final class AILockFilterDataProvider: NEFilterDataProvider {
    private let logger = Logger(subsystem: "com.laogu.ailock.filter-prototype", category: "flows")
    private var health: FilterHealthService?
    private let healthLock = NSLock()
    override func startFilter(completionHandler: @escaping (Error?) -> Void) {
        do {
            let policy = try (filterConfiguration.vendorConfiguration?["policyData"] as? Data).map(NetworkFilterPolicy.decoded) ?? NetworkFilterPolicy(revision: "00000000-0000-0000-0000-000000000000", blockedHosts: ExactHostPolicy(filterConfiguration.vendorConfiguration?["blockedHosts"] as? [String] ?? []).hosts).validated()
            guard let team = AuditIPCIdentity.team(),
                  let configuration = Bundle.main.object(forInfoDictionaryKey: "NetworkExtension") as? [String: Any],
                  configuration["NEMachServiceName"] as? String == team + ".com.laogu.ailock.filterprototype" else { throw ExactHostPolicy.Failure("过滤健康服务签名或服务名不匹配") }
            let service = FilterHealthService(policy: policy, team: team, serviceName: team + ".com.laogu.ailock.filterprototype")
            healthLock.lock(); let previous = health; health = service; healthLock.unlock(); previous?.stop()
            completionHandler(nil)
        } catch { completionHandler(error) }
    }
    override func stopFilter(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) { healthLock.lock(); let service = health; health = nil; healthLock.unlock(); service?.stop(); completionHandler() }
    override func handleNewFlow(_ flow: NEFilterFlow) -> NEFilterNewFlowVerdict {
        guard let socket = flow as? NEFilterSocketFlow else { return .allow() }
        let host = (socket.remoteEndpoint as? NWHostEndpoint).flatMap { try? ExactHostPolicy([$0.hostname]).hosts.first }
        healthLock.lock(); let service = health; healthLock.unlock()
        let blocked = service?.decision(host: host, auditToken: flow.sourceAppAuditToken) ?? false
        logger.notice("Flow host=\(host ?? "unknown", privacy: .private) blocked=\(blocked)")
        return blocked ? .drop() : .allow()
    }

}
NEProvider.startSystemExtensionMode()
dispatchMain()
