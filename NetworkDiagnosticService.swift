import Foundation
import Darwin

/// Measures DNS transactions, rather than using ICMP reachability as resolver speed.
enum NetworkDNSDiagnostics {
    struct Reply: Sendable {
        let output: String
        let succeeded: Bool
        let milliseconds: Double?
        let addresses: [String]
        init(_ output: String, status: Int32 = 0, type: String = "A") {
            self.output = output
            let normalized = output.replacingOccurrences(of: "\r\n", with: "\n")
            addresses = normalized.split(separator: "\n").compactMap { line in
                guard !line.hasPrefix(";") else { return nil }
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                guard fields.count >= 5, fields[3] == Substring(type), NetworkDiagnosticService.validIP(String(fields[4])) else { return nil }
                return String(fields[4])
            }
            succeeded = status == 0 && normalized.contains("status: NOERROR") && !addresses.isEmpty
            milliseconds = NetworkDiagnosticService.dnsMetrics(normalized).first { $0.name == "查询耗时" }.flatMap {
                Double($0.value.split(separator: " ").first ?? "")
            }.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }
    }
    static func run(target: String, server: String, source: String?, line: String) async throws -> NetworkDiagnosticResult {
        func query(_ name: String, type: String) async throws -> Reply {
            var args = ["+time=2", "+tries=1", name, type]
            if !server.isEmpty { args.insert("@" + server, at: 0) }
            if let source { args += ["-b", source] }
            do {
                let result = try await NetworkDiagnosticCommand.runStreaming("/usr/bin/dig", args, timeout: 4) { _ in }
                return Reply(result.output, status: result.status, type: type)
            } catch is CancellationError { throw CancellationError() }
            catch { return Reply(error.localizedDescription, status: 1, type: type) }
        }
        var replies: [Reply] = []
        for _ in 0..<3 { replies.append(try await query(target, type: "A")) }
        let ipv6 = try await query(target, type: "AAAA")
        // RFC 2606 reserves .invalid; a positive answer is suspicious even when CDNs differ.
        let negativeName = "ailock-" + UUID().uuidString.lowercased() + ".invalid"
        let negative = try await query(negativeName, type: "A")
        return result(target: target, server: server, line: line, replies: replies, ipv6: ipv6, negative: negative)
    }
    static func result(target: String, server: String, line: String, replies: [Reply], ipv6: Reply, negative: Reply) -> NetworkDiagnosticResult {
        let successful = replies.filter(\.succeeded)
        let times = successful.compactMap(\.milliseconds).sorted()
        var metrics: [NetworkDiagnosticMetric] = [.init(name: "DNS 服务器", value: server.isEmpty ? "系统 DNS" : server),
            .init(name: "查询成功率", value: "\(successful.count)/\(replies.count)")]
        if !times.isEmpty {
            let middle = times.count / 2
            let median = times.count % 2 == 0 ? (times[middle - 1] + times[middle]) / 2 : times[middle]
            metrics += [.init(name: "查询耗时", value: String(format: "%.1f ms", median)),
                .init(name: "最快查询", value: String(format: "%.1f ms", times[0])),
                .init(name: "最慢查询", value: String(format: "%.1f ms", times.last!))]
        }
        let addresses = Set(successful.flatMap(\.addresses)).sorted()
        if !addresses.isEmpty { metrics.append(.init(name: "A 记录", value: addresses.joined(separator: ", "))) }
        if ipv6.succeeded { metrics.append(.init(name: "AAAA 记录", value: ipv6.addresses.joined(separator: ", "))) }
        let suspicious = !negative.addresses.isEmpty
        let negativeStatus = suspicious ? "不存在域名返回地址，需核查" : negative.output.contains("status: NXDOMAIN") ? "NXDOMAIN 正常" : "未得到有效响应"
        metrics.append(.init(name: "不存在域名检查", value: negativeStatus))
        let fakeDNS = addresses.contains { address in
            guard let value = NetworkDiagnosticService.ipv4(address) else { return false }
            return value & 0xfffe0000 == 0xc6120000
        }
        if fakeDNS { metrics.append(.init(name: "解析环境", value: "返回 198.18/15 地址，可能经过 Fake DNS 代理")) }
        let passed = !fakeDNS && successful.count == replies.count && !successful.isEmpty && !suspicious && negative.output.contains("status: NXDOMAIN")
        let summary = fakeDNS ? "检测到 Fake DNS 地址，查询耗时可能仅代表本地代理" : suspicious ? "不存在域名被解析，可能受到 DNS 重定向或代理影响" : successful.isEmpty ? "未得到有效 A 记录，详见响应" : successful.count < replies.count ? "部分 DNS 查询失败，详见响应" : !negative.output.contains("status: NXDOMAIN") ? "解析成功，但不存在域名检查未验证" : "查询耗时为三次中位数，缓存及 CDN 会影响结果；解析差异不等于污染"
        let detail = "\(target)\n" + replies.enumerated().map { "A #\($0.offset + 1)\n\($0.element.output)" }.joined(separator: "\n\n") + "\n\nAAAA\n" + ipv6.output + "\n\n.invalid\n" + negative.output
        return .init("DNS · " + (server.isEmpty ? "系统 DNS" : server), line: line, passed: passed, summary: summary, metrics: metrics, details: detail)
    }
}

struct NetworkDiagnosticMetric: Codable, Sendable {
    let name: String
    let value: String
}

struct NetworkDiagnosticResult: Identifiable, Codable, Sendable {
    let id: UUID
    let date: Date
    let title: String
    let line: String
    let passed: Bool
    let summary: String
    let metrics: [NetworkDiagnosticMetric]
    let details: String
    init(_ title: String, line: String = "系统默认线路", passed: Bool = true, summary: String = "检查完成", metrics: [NetworkDiagnosticMetric] = [], details: String = "") {
        self.id = UUID(); self.date = Date()
        self.title = title; self.line = line; self.passed = passed; self.summary = summary; self.metrics = metrics; self.details = details
    }
}

struct NetworkDiagnosticInterface: Identifiable, Sendable {
    let name: String
    let address: String
    let mask: String
    let ipv6: Bool
    var id: String { name + ":" + address }
}

struct NetworkDiagnosticNode: Identifiable, Codable, Sendable {
    let id: String
    let name: String
    let region: String
    let download: String
    let upload: String?
    var city: String? = nil
    var carrier: String? = nil

    var localizedName: String {
        guard let city, let carrier else { return L10n.text(name) }
        let serverID = id.split(separator: "-").last.map(String.init) ?? id
        return "\(L10n.text(carrier)) · \(city) (#\(serverID))"
    }

    static let catalogKey = "networkDiagnostic.remoteNodeCatalog"
    static let catalogRevisionKey = "networkDiagnostic.remoteNodeCatalogRevision"
    static let builtIn: [Self] = [
        .init(id: "tuna", name: "清华镜像", region: "国内", download: "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz", upload: nil),
        .init(id: "aliyun", name: "阿里云镜像", region: "国内", download: "https://mirrors.aliyun.com/ubuntu/ls-lR.gz", upload: nil),
        .init(id: "shanghai-telecom", name: "上海电信", region: "中国大陆 · 中国电信上海", download: "http://speedtest1.online.sh.cn:8080/speedtest/random1000x1000.jpg", upload: "http://speedtest1.online.sh.cn:8080/speedtest/upload.php"),
        .init(id: "cloudflare", name: "Cloudflare", region: "海外服务（自动选点）", download: "https://speed.cloudflare.com/__down?bytes=4194304", upload: "https://speed.cloudflare.com/__up"),
        .init(id: "ovh", name: "OVH 法国", region: "国外", download: "https://proof.ovh.net/files/10Mb.dat", upload: nil)
    ]

    static var remote: [Self] {
        guard let data = UserDefaults.standard.data(forKey: catalogKey),
              let nodes = try? JSONDecoder().decode([Self].self, from: data) else { return [] }
        return nodes
    }

    static var defaults: [Self] {
        let remoteNodes = remote
        return remoteNodes.isEmpty ? builtIn : remoteNodes + builtIn
    }

    static func refreshFromGitHub() async {
        let sources: [(String, String)] = [
            ("中国电信", "https://raw.githubusercontent.com/spiritLHLS/speedtest.net-CN-ID/main/CN_Telecom.csv"),
            ("中国联通", "https://raw.githubusercontent.com/spiritLHLS/speedtest.net-CN-ID/main/CN_Unicom.csv"),
            ("中国移动", "https://raw.githubusercontent.com/spiritLHLS/speedtest.net-CN-ID/main/CN_Mobile.csv")
        ]

        do {
            let downloads = try await withThrowingTaskGroup(of: (String, Data).self) { group in
                for (carrier, address) in sources {
                    group.addTask {
                        guard let url = URL(string: address) else { throw URLError(.badURL) }
                        var request = URLRequest(url: url, timeoutInterval: 10)
                        request.setValue("AILock Network Diagnostics", forHTTPHeaderField: "User-Agent")
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let response = response as? HTTPURLResponse,
                              (200..<300).contains(response.statusCode),
                              !data.isEmpty, data.count <= 64 * 1024 else { throw URLError(.badServerResponse) }
                        return (carrier, data)
                    }
                }
                var results = [(String, Data)]()
                for try await result in group { results.append(result) }
                return results
            }

            let catalogs = sources.compactMap { carrier, _ in
                downloads.first(where: { $0.0 == carrier }).map { parseCSV(String(decoding: $0.1, as: UTF8.self), carrier: carrier) }
            }
            let updated = (0..<(catalogs.map(\.count).max() ?? 0)).flatMap { index in
                catalogs.compactMap { index < $0.count ? $0[index] : nil }
            }
            guard !updated.isEmpty else { return }
            let data = try JSONEncoder().encode(updated)
            UserDefaults.standard.set(data, forKey: catalogKey)
            UserDefaults.standard.set(UserDefaults.standard.integer(forKey: catalogRevisionKey) + 1, forKey: catalogRevisionKey)
        } catch {
            // Keep the last successful catalog and built-in nodes when GitHub is unavailable.
        }
    }

    private static func parseCSV(_ text: String, carrier: String) -> [Self] {
        var nodes = [Self]()
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
            guard fields.count >= 8 else { continue }
            guard fields[1] == "CN",
                  let port = Int(fields[6]), (1...65535).contains(port),
                  !fields[0].isEmpty, fields[0].allSatisfy({ $0.isNumber }),
                  fields[5].range(of: #"^[A-Za-z0-9.-]+$"#, options: .regularExpression) != nil else { continue }
            let serverID = fields[0]
            let host = fields[5]
            let city = fields[3].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !city.isEmpty else { continue }
            let root = "http://\(host):\(port)/speedtest"
            nodes.append(.init(id: "github-\(carrier)-\(serverID)", name: carrier, region: carrier,
                               download: root + "/random1000x1000.jpg", upload: root + "/upload.php",
                               city: city, carrier: carrier))
        }
        return nodes
    }
}

enum NetworkDiagnosticKind: String, CaseIterable, Identifiable, Sendable {
    case speed, nodes, regional, dns, route, local, ping, port, ipv6
    var id: String { rawValue }
    var title: String {
        switch self {
        case .speed: return "上传下载测速"; case .nodes: return "多节点测速"; case .dns: return "DNS 测试"
        case .regional: return "地区延时地图"
        case .route: return "路由追踪"; case .local: return "本机与同网段检查"; case .ping: return "延迟与丢包"
        case .port: return "TCP 端口测试"; case .ipv6: return "IPv6 连通性"
        }
    }
}

struct NetworkDiagnosticPlan: Sendable {
    var kind: NetworkDiagnosticKind
    var interfaces: [String] = [""]
    var target = "www.haidatas.com"
    var port = 443
    var dnsServers = ["", "223.5.5.5", "119.29.29.29", "1.1.1.1", "8.8.8.8"]
    var nodes = NetworkDiagnosticNode.defaults
    var latencyRegions = NetworkLatencyRegion.defaults
    var expectedResultCount: Int {
        kind == .local ? 1 : interfaces.count * (kind == .regional ? latencyRegions.count : kind == .nodes ? nodes.count : kind == .dns ? dnsServers.count : 1)
    }
    static func comprehensive(interfaces: [String], target: String, port: Int, resolver: String, nodes: [NetworkDiagnosticNode]) -> [Self] {
        [NetworkDiagnosticKind.local, .speed, .regional, .dns, .route, .ping, .port, .ipv6, .nodes].map { kind in
            var plan = Self(kind: kind)
            plan.interfaces = interfaces; plan.target = target; plan.port = port; plan.nodes = nodes
            if !resolver.isEmpty && !plan.dnsServers.contains(resolver) { plan.dnsServers.append(resolver) }
            return plan
        }
    }
}

struct NetworkDiagnosticSpeedSample: Sendable {
    let line: String
    let downloadMbps: Double?
    let uploadMbps: Double?
}

/// Progress frames use carriage returns and may arrive across several reads.
struct NetworkSpeedStreamParser {
    private var pending = ""
    mutating func consume(_ text: String, line: String) -> [NetworkDiagnosticSpeedSample] {
        pending += text.replacingOccurrences(of: "\r\n", with: "\n")
        var samples: [NetworkDiagnosticSpeedSample] = []
        while let separator = pending.firstIndex(where: { $0 == "\r" || $0 == "\n" }) {
            let frame = String(pending[..<separator])
            pending.removeSubrange(...separator)
            if let sample = Self.parse(frame, line: line) { samples.append(sample) }
        }
        if pending.count > 4096 { pending = String(pending.suffix(4096)) }
        return samples
    }
    static func parse(_ frame: String, line: String) -> NetworkDiagnosticSpeedSample? {
        func rate(_ direction: String) -> Double? {
            let pattern = direction + #":\s*capacity\s+([0-9]+(?:\.[0-9]+)?)\s+([kKmMgGtT]?bps)"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: frame, range: NSRange(frame.startIndex..., in: frame)),
                  let valueRange = Range(match.range(at: 1), in: frame), let unitRange = Range(match.range(at: 2), in: frame),
                  let value = Double(frame[valueRange]), value.isFinite else { return nil }
            let factor: Double
            switch frame[unitRange].lowercased() {
            case "kbps": factor = 0.001
            case "mbps": factor = 1
            case "gbps": factor = 1000
            case "tbps": factor = 1_000_000
            default: factor = 0.000001
            }
            return value * factor
        }
        guard let download = rate("Downlink"), let upload = rate("Uplink") else { return nil }
        return .init(line: line, downloadMbps: download, uploadMbps: upload)
    }
}

struct NetworkDiagnosticCommandResult: Sendable {
    let status: Int32
    let output: String
    let elapsed: Double
}

private actor NetworkDiagnosticProcessExit {
    private var exited = false
    private var waiter: CheckedContinuation<Void, Never>?
    func markExited() { exited = true; waiter?.resume(); waiter = nil }
    func wait() async {
        if exited { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

/// Direct argv invocation keeps user input out of shell commands. Output and lifetime are bounded.
enum NetworkDiagnosticCommand {
    static func run(_ executable: String, _ arguments: [String], timeout: Double = 15) throws -> NetworkDiagnosticCommandResult {
        try Task.checkCancellation()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-diagnostic-" + UUID().uuidString)
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.standardOutput = handle; process.standardError = handle
        let start = DispatchTime.now().uptimeNanoseconds
        try process.run()
        while process.isRunning {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
            if Task.isCancelled || elapsed > timeout {
                process.terminate()
                for _ in 0..<10 where process.isRunning { Thread.sleep(forTimeInterval: 0.05) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                try Task.checkCancellation()
                throw NSError(domain: "NetworkDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试超时，未得到完整结果"])
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        try Task.checkCancellation()
        try handle.synchronize()
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let data = try reader.read(upToCount: 64 * 1024) ?? Data()
        return .init(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self), elapsed: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }
    /// A PTY is required: networkQuality suppresses progress when stdout is a file or pipe.
    static func runStreaming(_ executable: String, _ arguments: [String], timeout: Double,
                             onOutput: (String) async -> Void) async throws -> NetworkDiagnosticCommandResult {
        try Task.checkCancellation()
        var master: Int32 = -1
        var slave: Int32 = -1
        var size = winsize(ws_row: 24, ws_col: 240, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&master, &slave, nil, nil, &size) == 0 else { throw POSIXError(.EIO) }
        let terminal = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        defer { try? terminal.close(); close(master) }
        guard fcntl(master, F_SETFL, O_NONBLOCK) != -1 else { throw POSIXError(.EIO) }
        let process = Process()
        let exit = NetworkDiagnosticProcessExit()
        process.terminationHandler = { _ in Task { await exit.markExited() } }
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"; environment["TERM"] = "xterm"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = terminal; process.standardError = terminal
        let start = DispatchTime.now().uptimeNanoseconds
        try process.run()
        try terminal.close()
        var output = Data()
        var bytes = [UInt8](repeating: 0, count: 4096)
        func drain() async {
            for _ in 0..<32 {
                let count = bytes.withUnsafeMutableBytes { Darwin.read(master, $0.baseAddress, $0.count) }
                guard count > 0 else { return }
                let chunk = Data(bytes.prefix(count))
                if output.count < 64 * 1024 { output.append(chunk.prefix(64 * 1024 - output.count)) }
                await onOutput(String(decoding: chunk, as: UTF8.self))
            }
        }
        while process.isRunning {
            await drain()
            if Task.isCancelled || Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9 > timeout {
                process.terminate()
                for _ in 0..<10 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                await exit.wait()
                try Task.checkCancellation()
                throw NSError(domain: "NetworkDiagnostics", code: 1, userInfo: [NSLocalizedDescriptionKey: "测试超时，未得到完整结果"])
            }
            // Cancellation is handled above so the child is always terminated before throwing.
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await exit.wait()
        await drain()
        try Task.checkCancellation()
        return .init(status: process.terminationStatus, output: String(decoding: output, as: UTF8.self), elapsed: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
    }

}

enum NetworkDiagnosticService {
    static func validTarget(_ input: String) -> Bool {
        guard !input.isEmpty, input.count <= 253, !input.hasPrefix("-") else { return false }
        var v6 = in6_addr()
        if input.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return true }
        return input.split(separator: ".", omittingEmptySubsequences: false).allSatisfy {
            !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 }
        }
    }
    static func validIP(_ input: String) -> Bool {
        var v4 = in_addr(); var v6 = in6_addr()
        return input.withCString { inet_pton(AF_INET, $0, &v4) == 1 || inet_pton(AF_INET6, $0, &v6) == 1 }
    }
    static func validEndpoint(_ input: String) -> Bool {
        guard let url = URL(string: input), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { return false }
        return url.user == nil && url.password == nil && url.fragment == nil
    }
    static func ipv4(_ text: String) -> UInt32? {
        var value = in_addr()
        guard text.withCString({ inet_pton(AF_INET, $0, &value) }) == 1 else { return nil }
        return UInt32(bigEndian: value.s_addr)
    }
    static func maskPrefix(_ mask: String) -> Int? {
        guard let value = ipv4(mask) else { return nil }
        let inverted = ~value
        guard inverted & (inverted &+ 1) == 0 else { return nil }
        return value.nonzeroBitCount
    }
    static func sameSubnet(_ a: String, _ b: String, mask: String) -> Bool {
        guard let a = ipv4(a), let b = ipv4(b), let m = ipv4(mask), maskPrefix(mask) != nil else { return false }
        return a & m == b & m
    }
    static func interfaces() -> [NetworkDiagnosticInterface] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [NetworkDiagnosticInterface] = []
        var current = head
        while let pointer = current {
            defer { current = pointer.pointee.ifa_next }
            let value = pointer.pointee
            guard let address = value.ifa_addr, value.ifa_flags & UInt32(IFF_UP) != 0, value.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  address.pointee.sa_family == AF_INET || address.pointee.sa_family == AF_INET6 else { continue }
            func numeric(_ address: UnsafePointer<sockaddr>?) -> String {
                guard let address else { return "" }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return "" }
                return String(cString: buffer)
            }
            result.append(.init(name: String(cString: value.ifa_name), address: numeric(address), mask: numeric(value.ifa_netmask), ipv6: address.pointee.sa_family == AF_INET6))
        }
        return result.sorted { ($0.name, $0.address) < ($1.name, $1.address) }
    }
    static func field(_ name: String, in output: String) -> String? {
        output.split(separator: "\n").compactMap { line -> String? in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == name ? parts[1] : nil
        }.first
    }
    static func dnsMetrics(_ output: String) -> [NetworkDiagnosticMetric] {
        var answers: [String] = []
        var queryTime: String?
        var server: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix(";; Query time:") { queryTime = line.replacingOccurrences(of: ";; Query time:", with: "").trimmingCharacters(in: .whitespaces) }
            if line.hasPrefix(";; SERVER:") { server = line.replacingOccurrences(of: ";; SERVER:", with: "").trimmingCharacters(in: .whitespaces) }
            if !line.hasPrefix(";") {
                let fields = line.split(whereSeparator: { $0.isWhitespace })
                if fields.count >= 5 && fields[3] == "A" { answers.append(String(fields[4])) }
            }
        }
        var metrics: [NetworkDiagnosticMetric] = []
        if let queryTime { metrics.append(.init(name: "查询耗时", value: queryTime)) }
        if !answers.isEmpty { metrics.append(.init(name: "A 记录", value: answers.joined(separator: ", "))) }
        if let server { metrics.append(.init(name: "DNS 服务器", value: server)) }
        return metrics
    }
    static func run(_ plan: NetworkDiagnosticPlan, liveSpeed: @Sendable (NetworkDiagnosticSpeedSample) async -> Void = { _ in }, emit: @Sendable (NetworkDiagnosticResult) async -> Void) async throws {
        guard validTarget(plan.target), (1...65535).contains(plan.port), plan.dnsServers.allSatisfy({ $0.isEmpty || validIP($0) }), plan.nodes.allSatisfy({ validEndpoint($0.download) && ($0.upload.map(validEndpoint) ?? true) }) else { throw POSIXError(.EINVAL) }
        if plan.kind == .local { await emit(try local()); return }
        if plan.kind == .regional {
            try await NetworkRegionalLatency.run(plan, emit: emit)
            return
        }
        for interface in plan.interfaces {
            try Task.checkCancellation()
            let line = interface.isEmpty ? "系统默认线路" : interface
            let source = interfaces().first { $0.name == interface && !$0.ipv6 }?.address
            if !interface.isEmpty && [.dns, .ping, .port].contains(plan.kind) && source == nil {
                await emit(.init(plan.kind.title, line: line, passed: false, summary: "该接口没有可用 IPv4 地址，无法绑定此项测试"))
                continue
            }
            switch plan.kind {
            case .nodes:
                for node in plan.nodes {
                    try Task.checkCancellation()
                    do { await emit(try nodeTest(node, interface: interface)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { await emit(.init(node.name, line: line, passed: false, summary: error.localizedDescription)) }
                }
            case .dns:
                for server in plan.dnsServers {
                    try Task.checkCancellation()
                    await emit(try await NetworkDNSDiagnostics.run(target: plan.target, server: server, source: source, line: line))
                }
            default:
                do {
                    let result: NetworkDiagnosticResult
                    switch plan.kind {
                    case .speed: result = try await speed(interface, nodes: plan.nodes, liveSpeed: liveSpeed)
                    case .route:
                        var args = ["-n", "-I", "-m", "16", "-q", "1", "-w", "1"]
                        if !interface.isEmpty { args += ["-i", interface] }
                        args.append(plan.target)
                        let r = try NetworkDiagnosticCommand.run("/usr/sbin/traceroute", args, timeout: 25)
                        result = .init("路由追踪 · " + plan.target, line: line, passed: r.status == 0, summary: "星号表示该跳未响应，不能据此判断断网；最多追踪 16 跳", details: r.output)
                    case .ping:
                        var args = ["-n", "-c", "6", "-i", "0.3", "-W", "1000", "-t", "10"]
                        if !interface.isEmpty { args += ["-b", interface] }
                        if let source { args += ["-S", source] }
                        args.append(plan.target)
                        let r = try NetworkDiagnosticCommand.run("/sbin/ping", args, timeout: 12)
                        result = .init("延迟与丢包 · " + plan.target, line: line, passed: r.status == 0, summary: "结果包含丢包率和 min/avg/max/stddev；ICMP 不响应不一定代表网络不可用", details: r.output)
                    case .port:
                        var args = ["-z", "-v", "-G", "4", "-w", "4"]
                        if !interface.isEmpty { args += ["-b", interface] }
                        if let source { args += ["-s", source] }
                        args += [plan.target, String(plan.port)]
                        let r = try NetworkDiagnosticCommand.run("/usr/bin/nc", args, timeout: 6)
                        result = .init("TCP · " + plan.target + ":" + String(plan.port), line: line, passed: r.status == 0, summary: r.status == 0 ? "端口连接成功" : "端口连接失败", details: r.output)
                    case .ipv6:
                        var args = curlArguments(interface) + ["--noproxy", "*", "-6", "--head", "--output", "/dev/null", "--write-out", "%{json}", "https://www.cloudflare.com"]
                        args += ["--max-time", "8"]
                        let r = try NetworkDiagnosticCommand.run("/usr/bin/curl", args, timeout: 10)
                        result = .init("IPv6 HTTPS", line: line, passed: r.status == 0, summary: r.status == 0 ? "IPv6 连接成功" : "IPv6 连接未成功，可能没有 IPv6 路由或目标不可达", details: r.output)
                    default: throw POSIXError(.EINVAL)
                    }
                    await emit(result)
                } catch is CancellationError { throw CancellationError() }
                catch { await emit(.init(plan.kind.title, line: line, passed: false, summary: error.localizedDescription)) }
            }
        }
    }
    private static func curlArguments(_ interface: String) -> [String] {
        // Explicit interface tests bypass environment/system proxies to measure that interface.
        var args = ["--silent", "--show-error", "--fail", "--connect-timeout", "4", "--max-time", "12", "--proto", "=http,https"]
        if !interface.isEmpty { args += ["--interface", interface, "--noproxy", "*"] }
        return args
    }
    static func parseTransfer(_ output: String) -> [String: Any]? {
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(output[start...end].utf8))) as? [String: Any]
    }
    private static func nodeTest(_ node: NetworkDiagnosticNode, interface: String) throws -> NetworkDiagnosticResult {
        let args = curlArguments(interface) + ["--range", "0-4194303", "--max-filesize", "4194304", "--output", "/dev/null", "--write-out", "%{json}", node.download]
        let download = try NetworkDiagnosticCommand.run("/usr/bin/curl", args, timeout: 14)
        guard download.status == 0, let json = parseTransfer(download.output), let bytes = json["size_download"] as? NSNumber, bytes.doubleValue >= 65536,
              let speed = json["speed_download"] as? NSNumber, let code = json["http_code"] as? NSNumber, [200, 206].contains(code.intValue) else {
            return .init(node.name, line: interface.isEmpty ? "系统默认线路" : interface, passed: false, summary: "节点下载失败或样本不足，请更换节点", details: node.download + "\n" + download.output)
        }
        func seconds(_ key: String) -> Double { (json[key] as? NSNumber)?.doubleValue ?? 0 }
        var metrics: [NetworkDiagnosticMetric] = [
            .init(name: "下载速度", value: String(format: "%.2f Mbps", speed.doubleValue * 8 / 1e6)),
            .init(name: "DNS 耗时", value: String(format: "%.1f ms", seconds("time_namelookup") * 1000)),
            .init(name: "TCP 握手", value: String(format: "%.1f ms", max(0, seconds("time_connect") - seconds("time_namelookup")) * 1000)),
            .init(name: "首字节耗时", value: String(format: "%.1f ms", seconds("time_starttransfer") * 1000)),
            .init(name: "连接 IP", value: json["remote_ip"] as? String ?? "—")
        ]
        var details = L10n.text(node.region) + "\n" + node.download + "\n" + download.output
        metrics.append(.init(name: "下载样本", value: String(format: "%.2f MiB", bytes.doubleValue / 1048576)))
        var summary = "下载样本含连接开销；VPN 或透明代理可能影响连接 IP 和性能"
        var passed = true
        if let upload = node.upload {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-upload-" + UUID().uuidString)
            try Data(repeating: 0x5A, count: 2 * 1024 * 1024).write(to: file, options: .atomic)
            defer { try? FileManager.default.removeItem(at: file) }
            let r = try NetworkDiagnosticCommand.run("/usr/bin/curl", curlArguments(interface) + ["--request", "POST", "--data-binary", "@" + file.path, "--output", "/dev/null", "--write-out", "%{json}", upload], timeout: 14)
            details += "\n" + upload + "\n" + r.output
            if r.status == 0, let j = parseTransfer(r.output), let value = j["speed_upload"] as? NSNumber, let amount = j["size_upload"] as? NSNumber, amount.intValue == 2 * 1024 * 1024, let code = j["http_code"] as? NSNumber, (200..<300).contains(code.intValue) {
                metrics.append(.init(name: "上传速度", value: String(format: "%.2f Mbps", value.doubleValue * 8 / 1e6)))
            } else { passed = false; summary = "下载完成，上传未成功；详见响应" }
        } else { metrics.append(.init(name: "上传速度", value: "该节点不支持上传")) }
        return .init(node.name, line: interface.isEmpty ? "系统默认线路" : interface, passed: passed, summary: summary, metrics: metrics, details: details)
    }
    private static func speed(_ interface: String, nodes: [NetworkDiagnosticNode], liveSpeed: @Sendable (NetworkDiagnosticSpeedSample) async -> Void) async throws -> NetworkDiagnosticResult {
        let line = interface.isEmpty ? "系统默认线路" : interface
        await liveSpeed(.init(line: line, downloadMbps: nil, uploadMbps: nil))
        let jsonURL = FileManager.default.temporaryDirectory.appendingPathComponent("ailock-speed-" + UUID().uuidString + ".json")
        guard FileManager.default.createFile(atPath: jsonURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw POSIXError(.EIO) }
        defer { try? FileManager.default.removeItem(at: jsonURL) }
        // getopt requires the optional JSON filename adjacent to -c.
        var args = ["-v", "-c" + jsonURL.path, "-M", "30"]
        if !interface.isEmpty { args += ["-I", interface] }
        var parser = NetworkSpeedStreamParser()
        let r: NetworkDiagnosticCommandResult
        do {
            r = try await NetworkDiagnosticCommand.runStreaming("/usr/bin/networkQuality", args, timeout: 40) { text in
                for sample in parser.consume(text, line: line) { await liveSpeed(sample) }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return try fallbackSpeed(interface, nodes: nodes, cause: error.localizedDescription)
        }
        let jsonText = (try? String(contentsOf: jsonURL, encoding: .utf8)) ?? ""
        guard r.status == 0, let json = parseTransfer(jsonText), let download = json["dl_throughput"] as? NSNumber, let upload = json["ul_throughput"] as? NSNumber, download.doubleValue > 0, upload.doubleValue > 0 else {
            return try fallbackSpeed(interface, nodes: nodes, cause: r.output + "\n" + jsonText)
        }
        var metrics = [NetworkDiagnosticMetric(name: "下载速度", value: String(format: "%.1f Mbps", download.doubleValue / 1e6)), .init(name: "上传速度", value: String(format: "%.1f Mbps", upload.doubleValue / 1e6))]
        if let latency = json["base_rtt"] as? NSNumber { metrics.append(.init(name: "空闲延迟", value: String(format: "%.1f ms", latency.doubleValue))) }
        if let rpm = json["responsiveness"] as? NSNumber { metrics.append(.init(name: "负载响应能力", value: String(format: "%.0f RPM", rpm.doubleValue))) }
        return .init("Apple 网络质量", line: line, metrics: metrics, details: jsonText + "\n" + r.output)
    }
    static func prioritizedUploadNodes(_ nodes: [NetworkDiagnosticNode]) -> [NetworkDiagnosticNode] {
        let uploadNodes = nodes.filter { $0.upload != nil }
        let preferredIDs = ["shanghai-telecom", "cloudflare"]
        let preferred = preferredIDs.compactMap { id in uploadNodes.first { $0.id == id } }
        return preferred + uploadNodes.filter { !preferredIDs.contains($0.id) }
    }
    private static func fallbackSpeed(_ interface: String, nodes: [NetworkDiagnosticNode], cause: String) throws -> NetworkDiagnosticResult {
        let line = interface.isEmpty ? "系统默认线路" : interface
        let selected = nodes.isEmpty ? NetworkDiagnosticNode.defaults : nodes
        let uploadNodes = Array(prioritizedUploadNodes(selected).prefix(3))
        let downloadNodes = Array(selected.filter { $0.upload == nil }.prefix(2))
        var failures = ["Apple networkQuality：\n" + cause]
        var partial: (node: NetworkDiagnosticNode, result: NetworkDiagnosticResult)?

        for node in uploadNodes {
            try Task.checkCancellation()
            do {
                let result = try nodeTest(node, interface: interface)
                let hasDownload = result.metrics.contains { $0.name == "下载速度" && NetworkDiagnosticPlots.number($0.value) != nil }
                let hasUpload = result.metrics.contains { $0.name == "上传速度" && NetworkDiagnosticPlots.number($0.value) != nil }
                if hasDownload && hasUpload {
                    return .init("上传下载测速", line: result.line, passed: result.passed,
                                 summary: "Apple 网络质量测速未成功，备用节点测速已完成。",
                                 metrics: result.metrics,
                                 details: failures.joined(separator: "\n\n") + "\n\n" + L10n.text("备用测速") + " (" + node.localizedName + "):\n" + result.details)
                }
                if hasDownload && partial == nil { partial = (node, result) }
                failures.append("\(node.name)：\n" + result.summary + "\n" + result.details)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(node.name)：" + error.localizedDescription)
            }
        }

        if let partial {
            let uploadUnavailable = partial.result.metrics.first { $0.name == "上传速度" }?.value == "该节点不支持上传"
            let summary = uploadUnavailable
                ? "下载已成功，但没有可用的上传节点。请查看详情，或在诊断参数中配置 POST 上传地址。"
                : "下载已成功，但所选节点的上传请求未成功。请查看详情中的 HTTP 状态和节点地址。"
            return .init("上传下载测速", line: partial.result.line, passed: false, summary: summary,
                         metrics: partial.result.metrics,
                         details: failures.joined(separator: "\n\n") + "\n\n备用测速：\n" + partial.result.details)
        }

        for node in downloadNodes {
            try Task.checkCancellation()
            do {
                let result = try nodeTest(node, interface: interface)
                let hasDownload = result.metrics.contains { $0.name == "下载速度" && NetworkDiagnosticPlots.number($0.value) != nil }
                failures.append("\(node.name)：\n" + result.summary + "\n" + result.details)
                if hasDownload {
                    return .init("上传下载测速", line: result.line, passed: false,
                                 summary: "下载已成功，但没有可用的上传节点。请查看详情，或在诊断参数中配置 POST 上传地址。",
                                 metrics: result.metrics,
                                 details: failures.joined(separator: "\n\n"))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures.append("\(node.name)：" + error.localizedDescription)
            }
        }

        return .init("上传下载测速", line: line, passed: false,
                     summary: "网络质量测速和备用节点均未能获取速度，请检查网络或测速节点。",
                     details: failures.joined(separator: "\n\n"))
    }
    static func subnetFindings(_ entries: [NetworkDiagnosticInterface], gateway: String?, routeInterface: String?) -> [String] {
        let v4 = entries.filter { !$0.ipv6 }
        var findings: [String] = []
        for entry in v4 {
            if maskPrefix(entry.mask) == nil { findings.append(entry.name + "：子网掩码不连续或无法读取") }
            if entry.address.hasPrefix("169.254.") { findings.append(entry.name + "：自分配地址，建议检查 DHCP") }
            if entry.name == routeInterface, let gateway, validIP(gateway), !entry.name.hasPrefix("utun"), !sameSubnet(entry.address, gateway, mask: entry.mask) {
                findings.append(entry.name + "：默认网关不在当前网段，请核查路由；点对点连接可能是正常配置")
            }
        }
        for i in v4.indices {
            for j in v4.indices where j > i && v4[i].name != v4[j].name && !v4[i].name.hasPrefix("utun") && !v4[j].name.hasPrefix("utun") {
                let a = v4[i], b = v4[j]
                if a.address == b.address { findings.append(a.name + " / " + b.name + "：本机接口使用相同 IP") }
                if sameSubnet(a.address, b.address, mask: a.mask) || sameSubnet(a.address, b.address, mask: b.mask) { findings.append(a.name + " / " + b.name + "：网段重叠，可能影响选路") }
            }
        }
        if v4.isEmpty { findings.append("未发现已启用的 IPv4 接口") }
        return findings
    }
    static func publicIPAddress(_ output: String) -> String? {
        let address = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validIP(address) else { return nil }
        if let value = ipv4(address) {
            let first = value >> 24
            let second = (value >> 16) & 255
            guard first != 0, first != 10, first != 127, first < 224,
                  !(first == 169 && second == 254), !(first == 172 && (16...31).contains(second)),
                  !(first == 192 && second == 168), !(first == 100 && (64...127).contains(second)),
                  !(first == 198 && (18...19).contains(second)) else { return nil }
        } else {
            // Public IPv6 unicast addresses currently belong to 2000::/3.
            guard let first = address.first, first == "2" || first == "3" else { return nil }
        }
        return address
    }
    private static func publicIPGeolocation(_ output: String) -> String? {
        struct Response: Decodable {
            let success: Bool
            let country: String?
            let region: String?
            let city: String?
        }
        guard let data = output.data(using: .utf8),
              let response = try? JSONDecoder().decode(Response.self, from: data),
              response.success else { return nil }
        var components: [String] = []
        for value in [response.country, response.region, response.city].compactMap({ $0?.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if !value.isEmpty, !components.contains(value) { components.append(value) }
        }
        return components.isEmpty ? nil : components.joined(separator: " · ")
    }

    private static func local() throws -> NetworkDiagnosticResult {
        let entries = interfaces()
        let route = try NetworkDiagnosticCommand.run("/sbin/route", ["-n", "get", "default"], timeout: 4)
        let gateway = field("gateway", in: route.output)
        let routeInterface = field("interface", in: route.output)
        var findings = subnetFindings(entries, gateway: gateway, routeInterface: routeInterface)
        if route.status != 0 { findings.append("没有读取到 IPv4 默认路由，IPv6 或 VPN 网络需结合路由表判断") }
        var details = entries.map { "\($0.name)  \($0.ipv6 ? "IPv6" : "IPv4")  \($0.address)  mask=\($0.mask)" }.joined(separator: "\n")
        details += "\n\n" + route.output
        for (path, args) in [("/usr/sbin/networksetup", ["-listallhardwareports"]), ("/usr/sbin/scutil", ["--dns"]), ("/usr/sbin/scutil", ["--proxy"]), ("/usr/sbin/netstat", ["-rn"]), ("/usr/sbin/arp", ["-an"])] {
            try Task.checkCancellation()
            let r = try NetworkDiagnosticCommand.run(path, args, timeout: 4)
            details += "\n\n" + path + " " + args.joined(separator: " ") + "\n" + r.output
        }
        var metrics: [NetworkDiagnosticMetric] = [.init(name: "默认网关", value: gateway ?? "未读取"), .init(name: "默认接口", value: routeInterface ?? "未读取"), .init(name: "VPN 隧道接口", value: entries.contains { $0.name.hasPrefix("utun") } ? "检测到隧道接口，未确认 VPN 是否使用" : "未检测到")]
        // The address is the visible egress IP; system proxies and VPNs can change it.
        var publicIP: String?
        for endpoint in ["https://ip.3322.net", "https://api.ipify.org", "https://checkip.amazonaws.com"] {
            try Task.checkCancellation()
            do {
                let response = try NetworkDiagnosticCommand.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--location", "--connect-timeout", "3", "--max-time", "6", endpoint], timeout: 7)
                details += "\n\n公网 IP · " + endpoint + "\n" + response.output
                if response.status == 0, let address = publicIPAddress(response.output) { publicIP = address; break }
            } catch is CancellationError { throw CancellationError() }
            catch { details += "\n\n公网 IP · " + endpoint + "\n" + error.localizedDescription }
        }
        var publicIPLocation: String?
        if let publicIP {
            let language = L10n.isEnglish ? "en" : "zh-CN"
            let endpoint = "https://ipwho.is/\(publicIP)?lang=\(language)"
            do {
                try Task.checkCancellation()
                let response = try NetworkDiagnosticCommand.run("/usr/bin/curl", ["--silent", "--show-error", "--fail", "--location", "--connect-timeout", "3", "--max-time", "5", endpoint], timeout: 6)
                details += "\n\n" + (L10n.isEnglish ? "Public IP location · " : "公网 IP 归属地 · ") + endpoint + "\n" + response.output
                if response.status == 0 { publicIPLocation = publicIPGeolocation(response.output) }
            } catch is CancellationError { throw CancellationError() }
            catch {
                details += (L10n.isEnglish ? "\n\nPublic IP location lookup failed: " : "\n\n公网 IP 归属地查询失败：") + error.localizedDescription
            }
            details += L10n.isEnglish
                ? "\nGeolocation is an estimate from an IP database. VPNs or proxies may show the location of their public exit IP. The public IP is sent to ipwho.is for this lookup."
                : "\n地理位置由 IP 数据库估算；使用 VPN 或代理时显示其公网出口地址的归属地。查询会向 ipwho.is 发送公网 IP。"
        }
        let publicIPValue = publicIP.map { address in
            publicIPLocation.map { address + " · " + $0 } ?? address
        } ?? "未读取"
        metrics.append(.init(name: "公网 IP", value: publicIPValue))
        metrics += entries.map { .init(name: $0.name + ($0.ipv6 ? " IPv6" : " IPv4"), value: $0.address + ($0.ipv6 ? "" : " / " + String(maskPrefix($0.mask) ?? -1))) }
        details += "\n\n" + (findings.isEmpty ? "未发现本机网段配置异常" : findings.joined(separator: "\n")) + "\n仅核查本机配置与已有 ARP 邻居，不扫描整个局域网；不能据此排除其他设备的 IP 冲突。"
        return .init("本机与同网段检查", passed: findings.isEmpty, summary: findings.isEmpty ? "未发现本机网段配置异常" : findings.joined(separator: "\n"), metrics: metrics, details: details)
    }
}

struct NetworkDiagnosticPlotSample: Identifiable, Sendable {
    let index: Int
    let address: String?
    let milliseconds: Double?
    var id: Int { index }
}

/// Interpret tool output for plotting. Missing responses stay nil, never become zero latency.
enum NetworkDiagnosticPlots {
    static func number(_ text: String) -> Double? {
        guard let range = text.range(of: #"^[\s<]*([0-9]+(?:\.[0-9]+)?)"#, options: .regularExpression),
              let value = Double(text[range].trimmingCharacters(in: CharacterSet(charactersIn: " <\t\n"))), value.isFinite else { return nil }
        return value
    }
    static func metric(_ name: String, in result: NetworkDiagnosticResult) -> Double? {
        result.metrics.first { $0.name == name }.flatMap { number($0.value) }
    }
    private static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), match.numberOfRanges > 1, let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
    static func ping(_ output: String) -> [NetworkDiagnosticPlotSample] {
        var observed: [Int: Double] = [:]
        for line in output.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n") {
            guard let sequence = match(#"icmp_seq[= ](\d+)"#, in: String(line)).flatMap(Int.init), let time = match(#"time[=<]([0-9.]+)\s*ms"#, in: String(line)).flatMap(Double.init), time.isFinite else { continue }
            observed[sequence] = time
        }
        let transmitted = match(#"(\d+) packets transmitted"#, in: output).flatMap(Int.init)
        let count = min(1000, max(transmitted ?? 0, (observed.keys.max().map { $0 + 1 } ?? 0)))
        return (0..<count).map { .init(index: $0, address: nil, milliseconds: observed[$0]) }
    }
    static func packetLoss(_ output: String) -> Double? {
        match(#"([0-9.]+)% packet loss"#, in: output).flatMap(Double.init)
    }
    static func route(_ output: String) -> [NetworkDiagnosticPlotSample] {
        output.split(separator: "\n").compactMap { line in
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, let hop = Int(fields[0]), (1...64).contains(hop) else { return nil }
            let address = fields[1] == "*" ? nil : String(fields[1])
            let time = match(#"([0-9.]+)\s+ms"#, in: String(line)).flatMap(Double.init)
            return .init(index: hop, address: address, milliseconds: time)
        }
    }
}

/// Both build paths bundle these files; the map never depends on a live map API.
enum NetworkDiagnosticAssets {
    static func data(_ filename: String) -> Data? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let url = bundle.url(forResource: filename, withExtension: "json", subdirectory: "NetworkDiagnostics") else { return nil }
        return try? Data(contentsOf: url)
    }
}

struct NetworkLatencyTarget: Codable, Sendable {
    let address: String
    let carrier: String
    let source: String?
    init(address: String, carrier: String, source: String? = nil) {
        self.address = address
        self.carrier = carrier
        self.source = source
    }
}
struct NetworkLatencyRegion: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let englishName: String
    let overseas: Bool
    let targets: [NetworkLatencyTarget]
    static let defaults: [Self] = {
        guard let data = NetworkDiagnosticAssets.data("latency-nodes") else { return [] }
        return (try? JSONDecoder().decode([Self].self, from: data)) ?? []
    }()
}

struct NetworkProvinceGeometry: Identifiable, Sendable {
    let id: String
    let center: [Double]
    let polygons: [[[[Double]]]]
    static let defaults: [Self] = {
        guard let data = NetworkDiagnosticAssets.data("china-provinces"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = json["features"] as? [[String: Any]] else { return [] }
        return features.compactMap { feature in
            guard let properties = feature["properties"] as? [String: Any], let name = properties["name"] as? String,
                  let geometry = feature["geometry"] as? [String: Any] else { return nil }
            let center = properties["cp"] as? [Double] ?? [properties["longitude"] as? Double ?? 0, properties["latitude"] as? Double ?? 0]
            let polygons: [[[[Double]]]]
            if geometry["type"] as? String == "Polygon", let rings = geometry["coordinates"] as? [[[Double]]] { polygons = [rings] }
            else if let value = geometry["coordinates"] as? [[[[Double]]]] { polygons = value }
            else { return nil }
            return .init(id: name, center: center, polygons: polygons)
        }
    }()
}

/// Regional resolver IPs are landmarks, not a guarantee of physical server location.
/// The bounded group probes from this Mac, rather than using remote-to-target APIs.
enum NetworkRegionalLatency {
    static func average(_ output: String) -> Double? {
        // Ping's summary includes late replies that -W can suppress in individual lines.
        if let regex = try? NSRegularExpression(pattern: #"(?:round-trip|rtt)[^\r\n=]*=\s*[0-9.]+/([0-9.]+)/"#),
           let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
           let range = Range(match.range(at: 1), in: output), let value = Double(output[range]), value.isFinite, value >= 0 {
            return value
        }
        let values = NetworkDiagnosticPlots.ping(output).compactMap(\.milliseconds).filter { $0.isFinite && $0 >= 0 }
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }
    static func result(_ region: NetworkLatencyRegion, target: NetworkLatencyTarget?, interface: String, output: String, details: String) -> NetworkDiagnosticResult {
        let average = average(output)
        var metrics: [NetworkDiagnosticMetric] = [.init(name: "地区 ID", value: region.id)]
        if let target {
            metrics += [.init(name: "节点地址", value: target.address), .init(name: "运营商", value: target.carrier)]
            if let source = target.source { metrics.append(.init(name: "节点来源", value: source)) }
        }
        if let average { metrics.append(.init(name: "平均延迟", value: String(format: "%.1f ms", average))) }
        if let loss = NetworkDiagnosticPlots.packetLoss(output) { metrics.append(.init(name: "丢包率", value: String(format: "%.0f%%", loss))) }
        return .init(region.name, line: interface.isEmpty ? "系统默认线路" : interface, passed: average != nil,
                     summary: average == nil ? "节点未响应，不能据此判断该地区断网" : "本机到地区代表节点的 ICMP 往返延时", metrics: metrics, details: details)
    }
    static func probe(_ region: NetworkLatencyRegion, interface: String) async throws -> NetworkDiagnosticResult {
        let source = NetworkDiagnosticService.interfaces().first { $0.name == interface && !$0.ipv6 }?.address
        if !interface.isEmpty && source == nil {
            return result(region, target: nil, interface: interface, output: "", details: "当前接口没有可用的 IPv4 地址")
        }
        var details = "ICMP · regional DNS landmarks; sourced fallbacks use 1 probe\n"
        var lastOutput = ""
        var lastTarget: NetworkLatencyTarget?
        let regionalTargets = region.targets
        let fallbackTargets = [
            NetworkLatencyTarget(address: "223.5.5.5", carrier: "全国备用", source: "https://help.aliyun.com/zh/dns/free-service-disclaimer"),
            NetworkLatencyTarget(address: "114.114.114.114", carrier: "全国备用", source: "https://www.114dns.com/")
        ].filter { fallback in !regionalTargets.contains { $0.address == fallback.address } }
        for target in regionalTargets + fallbackTargets {
            try Task.checkCancellation()
            guard NetworkDiagnosticService.validTarget(target.address) else { continue }
            lastTarget = target
            let sourcedFallback = target.source != nil
            var args = ["-n", "-c", sourcedFallback ? "1" : "3", "-i", "0.2", "-W", sourcedFallback ? "600" : "800", "-t", "3"]
            if !interface.isEmpty { args += ["-b", interface] }
            if let source { args += ["-S", source] }
            args.append(target.address)
            do {
                let response = try await NetworkDiagnosticCommand.runStreaming("/sbin/ping", args, timeout: sourcedFallback ? 2 : 4) { _ in }
                lastOutput = response.output
                details += "\n" + target.carrier + " · " + target.address + (target.source.map { " · " + $0 } ?? "") + "\n" + response.output
                if average(response.output) != nil {
                    return result(region, target: target, interface: interface, output: response.output, details: details)
                }
            } catch is CancellationError { throw CancellationError() }
            catch { lastOutput = ""; details += "\n" + target.address + "\n" + error.localizedDescription }
        }
        return result(region, target: lastTarget, interface: interface, output: lastOutput, details: details)
    }
    static func run(_ plan: NetworkDiagnosticPlan, emit: @Sendable (NetworkDiagnosticResult) async -> Void) async throws {
        guard !plan.latencyRegions.isEmpty else {
            throw NSError(domain: "NetworkDiagnostics", code: 2, userInfo: [NSLocalizedDescriptionKey: "地区节点数据未加载"])
        }
        for interface in plan.interfaces {
            try await withThrowingTaskGroup(of: NetworkDiagnosticResult.self) { group in
                var iterator = plan.latencyRegions.makeIterator()
                for _ in 0..<min(6, plan.latencyRegions.count) {
                    if let region = iterator.next() { group.addTask { try await probe(region, interface: interface) } }
                }
                while let result = try await group.next() {
                    try Task.checkCancellation()
                    await emit(result)
                    if let region = iterator.next() { group.addTask { try await probe(region, interface: interface) } }
                }
            }
        }
    }
}
