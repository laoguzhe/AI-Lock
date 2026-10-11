import Foundation

struct NetworkObservation {
    let connections: [NetworkConnection]
    let sampledAt: Date
    let age: TimeInterval
    let coverage = "可访问进程的 TCP / UDP 快照；轮询可能遗漏短连接"
    func listeningPorts(for processes: [MonitoredProcess]) -> [pid_t: [Int]] {
        let identities = Dictionary(processes.map { ($0.pid, $0.startTime) }, uniquingKeysWith: { first, _ in first })
        let valid = connections.filter { entry in
            guard let start = entry.processStartTime else { return false }
            return identities[entry.pid] == start
        }
        return NetworkObservation(connections: valid, sampledAt: sampledAt, age: age).listeningPorts
    }
    var listeningPorts: [pid_t: [Int]] {
        var ports: [pid_t: Set<Int>] = [:]
        for entry in connections where entry.protocolName == "TCP" && entry.state == "LISTEN" && entry.pid > 0 {
            guard let token = entry.local.split(separator: ":").last, let port = Int(token), (1...65535).contains(port) else { continue }
            ports[entry.pid, default: []].insert(port)
        }
        return ports.mapValues { $0.sorted() }
    }
}

/// Shared command backend, called off-main. A serial queue coalesces overlapping requests.
final class NetworkObservationService {
    static let shared = NetworkObservationService()
    private let queue = DispatchQueue(label: "com.laogu.ailock.network-observation", qos: .utility)
    private let fetch: () throws -> [NetworkConnection]
    private let clock: () -> TimeInterval
    private var cached: [NetworkConnection]?
    private var fetchedAt: TimeInterval?
    private var sampledAt = Date.distantPast
    init(fetch: @escaping () throws -> [NetworkConnection] = NetworkInspector.connections,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.fetch = fetch; self.clock = clock
    }
    func observation(maxAge: TimeInterval = 3) throws -> NetworkObservation {
        try queue.sync {
            let now = clock()
            if let cached, let fetchedAt, now >= fetchedAt, now - fetchedAt <= maxAge {
                return NetworkObservation(connections: cached, sampledAt: sampledAt, age: now - fetchedAt)
            }
            let connections = try fetch()
            cached = connections; fetchedAt = clock(); sampledAt = Date()
            return NetworkObservation(connections: connections, sampledAt: sampledAt, age: 0)
        }
    }
}
