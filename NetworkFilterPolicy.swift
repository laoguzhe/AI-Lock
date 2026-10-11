import Foundation

struct SignedApplicationIdentity: Codable, Equatable, Hashable {
    let identifier: String
    let teamID: String
    func validated() throws -> Self {
        let characters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard !identifier.isEmpty, identifier.utf8.count <= 255, identifier.unicodeScalars.allSatisfy({ characters.contains($0) }),
              teamID.count == 10, teamID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789").contains($0) }) else { throw ExactHostPolicy.Failure("应用签名标识无效") }
        return self
    }
}
struct ApplicationBlockRule: Codable, Equatable, Hashable, Identifiable {
    let application: SignedApplicationIdentity
    let host: String?
    var id: String { application.teamID + "/" + application.identifier + "/" + (host ?? "*") }
}
struct NetworkFilterPolicy: Codable, Equatable {
    var revision: String
    var blockedHosts: [String]
    var applications: [ApplicationBlockRule]
    var automaticallyRecover: Bool
    init(revision: String = UUID().uuidString, blockedHosts: [String] = [], applications: [ApplicationBlockRule] = [], automaticallyRecover: Bool = false) {
        self.revision = revision; self.blockedHosts = blockedHosts; self.applications = applications; self.automaticallyRecover = automaticallyRecover
    }
    func validated() throws -> Self {
        guard UUID(uuidString: revision) != nil, applications.count <= 128 else { throw ExactHostPolicy.Failure("规则版本无效或超过 128 条应用规则") }
        let hosts = try ExactHostPolicy(blockedHosts).hosts
        let rules = try applications.map { rule in
            ApplicationBlockRule(application: try rule.application.validated(), host: try rule.host.map { try ExactHostPolicy([$0]).hosts[0] })
        }
        return Self(revision: revision, blockedHosts: hosts, applications: Array(Set(rules)).sorted { $0.id < $1.id }, automaticallyRecover: automaticallyRecover)
    }
    func blocks(host: String?, application: SignedApplicationIdentity?) -> Bool {
        if let host, blockedHosts.contains(host) { return true }
        guard let application else { return false }
        return applications.contains { $0.application == application && ($0.host == nil || $0.host == host) }
    }
    func encoded() throws -> Data { try JSONEncoder().encode(validated()) }
    static func decoded(_ data: Data) throws -> Self {
        guard data.count <= 128 * 1024 else { throw ExactHostPolicy.Failure("规则数据过大") }
        return try JSONDecoder().decode(Self.self, from: data).validated()
    }
}

/// Only a failed provider heartbeat triggers recovery. Internet reachability is not proof of a filter fault.
struct FilterHealthStateMachine {
    enum Action: Equatable { case none, reconnect, disableFilter }
    private(set) var failures = 0
    private(set) var recovering = false
    mutating func observe(healthy: Bool, networkAvailable: Bool, suspended: Bool, automaticallyRecover: Bool) -> Action {
        if suspended || !networkAvailable { failures = 0; return .none }
        if healthy { failures = 0; recovering = false; return .none }
        guard !recovering else { return .none }
        failures = min(3, failures + 1)
        if failures < 3 { return .reconnect }
        if automaticallyRecover { recovering = true; return .disableFilter }
        return .none
    }
    mutating func reset() { failures = 0; recovering = false }
}

/// Runs inside the provider, so an opted-in recovery still works when the host app exits.
struct FilterRecoveryLease {
    private(set) var lastHeartbeat: TimeInterval
    var automaticallyRecover: Bool
    init(now: TimeInterval, automaticallyRecover: Bool) { self.lastHeartbeat = now; self.automaticallyRecover = automaticallyRecover }
    mutating func renew(now: TimeInterval) { lastHeartbeat = now }
    mutating func shouldBypass(now: TimeInterval) -> Bool {
        if now < lastHeartbeat { lastHeartbeat = now; return false }
        return automaticallyRecover && now - lastHeartbeat >= 30
    }
}
