import XCTest
@testable import AILockCore

final class NetworkDiagnosticsTests: XCTestCase {
    func testDNSRepeatedQueriesUseMedianAndDoNotTreatCDNDifferencesAsPollution() {
        func reply(_ ms: Int, _ address: String) -> NetworkDNSDiagnostics.Reply {
            .init(";; status: NOERROR\r\nexample.com. 60 IN A \(address)\r\n;; Query time: \(ms) msec\r\n")
        }
        let result = NetworkDNSDiagnostics.result(target: "example.com", server: "", line: "en0", replies: [reply(100, "1.1.1.1"), reply(10, "8.8.8.8"), reply(20, "1.1.1.1")], ipv6: .init(";; status: NOERROR\nexample.com. 60 IN AAAA 2606:4700::1111", type: "AAAA"), negative: .init(";; status: NXDOMAIN"))
        XCTAssertTrue(result.passed)
        XCTAssertEqual(NetworkDiagnosticPlots.metric("查询耗时", in: result), 20)
        XCTAssertEqual(result.metrics.first { $0.name == "查询成功率" }?.value, "3/3")
        XCTAssertTrue(result.metrics.contains { $0.name == "AAAA 记录" })
        let failed = NetworkDNSDiagnostics.result(target: "example.com", server: "1.1.1.1", line: "", replies: [.init("timeout", status: 1)], ipv6: .init(""), negative: .init(";; status: NXDOMAIN"))
        XCTAssertFalse(failed.passed)
        XCTAssertNil(NetworkDiagnosticPlots.metric("查询耗时", in: failed))
        let redirected = NetworkDNSDiagnostics.result(target: "example.com", server: "", line: "", replies: [reply(10, "1.1.1.1")], ipv6: .init(""), negative: reply(5, "198.18.0.1"))
        XCTAssertFalse(redirected.passed)
        XCTAssertTrue(redirected.summary.contains("重定向"))
        let fake = NetworkDNSDiagnostics.result(target: "example.com", server: "", line: "", replies: [reply(0, "198.19.0.1")], ipv6: .init(""), negative: .init(";; status: NXDOMAIN"))
        XCTAssertFalse(fake.passed)
        XCTAssertTrue(fake.summary.contains("Fake DNS"))
    }
    func testRegionalAssetsCoverEveryProvinceAndUseValidTargets() {
        let regions = NetworkLatencyRegion.defaults
        let provinces = NetworkProvinceGeometry.defaults
        XCTAssertEqual(provinces.count, 34)
        XCTAssertEqual(Set(regions.filter { !$0.overseas }.map(\.id)), Set(provinces.map(\.id)))
        XCTAssertEqual(regions.filter(\.overseas).count, 4)
        XCTAssertEqual(Set(regions.map(\.id)).count, regions.count)
        XCTAssertTrue(regions.allSatisfy { !$0.targets.isEmpty && $0.targets.allSatisfy { NetworkDiagnosticService.publicIPAddress($0.address) != nil } })
        XCTAssertTrue(provinces.allSatisfy { $0.center.count == 2 && $0.center[0] > 70 && !$0.polygons.isEmpty })
    }
    func testRegionalLatencyMissingAndPartialReplies() {
        let region = NetworkLatencyRegion(id: "test", name: "Test", englishName: "Test", overseas: false, targets: [.init(address: "127.0.0.1", carrier: "test")])
        let missing = NetworkRegionalLatency.result(region, target: region.targets.first, interface: "en0", output: "3 packets transmitted, 0 packets received, 100.0% packet loss", details: "")
        XCTAssertFalse(missing.passed)
        XCTAssertNil(NetworkDiagnosticPlots.metric("平均延迟", in: missing))
        let output = "64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=20.0 ms\n64 bytes from 127.0.0.1: icmp_seq=2 ttl=64 time=40.0 ms\n3 packets transmitted, 2 packets received, 33.3% packet loss"
        let partial = NetworkRegionalLatency.result(region, target: region.targets.first, interface: "", output: output, details: output)
        XCTAssertTrue(partial.passed)
        XCTAssertEqual(NetworkDiagnosticPlots.metric("平均延迟", in: partial), 30)
        XCTAssertEqual(NetworkDiagnosticPlots.metric("丢包率", in: partial), 33)
        XCTAssertEqual(partial.line, "系统默认线路")
    }
    func testRegionalLatencyUsesReportedSummaryWithLateReplies() {
        let output = "Request timeout for icmp_seq 0\r\n64 bytes from 127.0.0.1: icmp_seq=0 ttl=64 time=10.0 ms\r\n64 bytes from 127.0.0.1: icmp_seq=1 ttl=64 time=20.0 ms\r\n3 packets transmitted, 3 packets received, 0.0% packet loss\r\nround-trip min/avg/max/stddev = 10.000/20.000/30.000/8.164 ms\r\n"
        XCTAssertEqual(NetworkDiagnosticPlots.ping(output).compactMap(\.milliseconds), [10, 20])
        XCTAssertEqual(NetworkRegionalLatency.average(output), 20)
    }
    func testRegionalProbeUsesLocalICMP() async throws {
        let region = NetworkLatencyRegion(id: "loopback", name: "Loopback", englishName: "Loopback", overseas: true, targets: [.init(address: "127.0.0.1", carrier: "local")])
        let result = try await NetworkRegionalLatency.probe(region, interface: "")
        XCTAssertTrue(result.passed)
        XCTAssertNotNil(NetworkDiagnosticPlots.metric("平均延迟", in: result))
        XCTAssertEqual(result.metrics.first { $0.name == "节点地址" }?.value, "127.0.0.1")
    }
    func testRegionalRunCancellationStopsProbes() async throws {
        var plan = NetworkDiagnosticPlan(kind: .regional)
        plan.latencyRegions = (0..<10).map { NetworkLatencyRegion(id: String($0), name: "Loopback", englishName: "Loopback", overseas: false, targets: [.init(address: "127.0.0.1", carrier: "local")]) }
        let task = Task { try await NetworkRegionalLatency.run(plan) { _ in } }
        try await Task.sleep(nanoseconds: 70_000_000)
        task.cancel()
        do { try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testPublicIPResponseValidation() {
        XCTAssertEqual(NetworkDiagnosticService.publicIPAddress(" 8.8.8.8\n"), "8.8.8.8")
        XCTAssertEqual(NetworkDiagnosticService.publicIPAddress("2606:4700::1111"), "2606:4700::1111")
        for value in ["192.168.1.1", "127.0.0.1", "198.18.0.1", "100.64.0.1", "fe80::1", "::1", "<html>error</html>", "8.8.8.8\n1.1.1.1"] {
            XCTAssertNil(NetworkDiagnosticService.publicIPAddress(value), value)
        }
    }
    func testLiveSpeedParserHandlesSplitFramesAndUnits() {
        var parser = NetworkSpeedStreamParser()
        XCTAssertTrue(parser.consume("\r\u{1b}[2KDownlink: capacity 12.500 Mbps - Up", line: "en0").isEmpty)
        let samples = parser.consume("link: capacity 750.000 Kbps\rDownlink: capacity 1.25 Gbps - Uplink: capacity 0.000 Mbps\r\n", line: "en0")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(samples[0].line, "en0")
        XCTAssertEqual(samples[0].downloadMbps, 12.5)
        XCTAssertEqual(samples[0].uploadMbps, 0.75)
        XCTAssertEqual(samples[1].downloadMbps, 1250)
        XCTAssertEqual(samples[1].uploadMbps, 0)
        XCTAssertNil(NetworkSpeedStreamParser.parse("Downlink: capacity nan Mbps - Uplink: capacity 1 Mbps", line: ""))
        XCTAssertNil(NetworkSpeedStreamParser.parse("==== SUMMARY ====", line: ""))
    }
    func testStreamingEmitsBeforeProcessFinishes() async throws {
        // The child waits for a file created by the output callback; buffering until exit would time out.
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: marker) }
        let script = "printf 'Downlink: capacity 12.5 Mbps - Uplink: capacity 8.0 Mbps\\r'; while [ ! -f \"$1\" ]; do sleep 0.05; done"
        var parser = NetworkSpeedStreamParser()
        var samples: [NetworkDiagnosticSpeedSample] = []
        let result = try await NetworkDiagnosticCommand.runStreaming("/bin/sh", ["-c", script, "stream-test", marker.path], timeout: 3) { output in
            samples += parser.consume(output, line: "en0")
            if !samples.isEmpty { FileManager.default.createFile(atPath: marker.path, contents: Data()) }
        }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(samples.first?.downloadMbps, 12.5)
        XCTAssertEqual(samples.first?.uploadMbps, 8)
    }
    func testStreamingTimeoutAndCancellation() async throws {
        let timeout = Task.detached { try await NetworkDiagnosticCommand.runStreaming("/bin/sleep", ["5"], timeout: 0.1) { _ in } }
        do { _ = try await timeout.value; XCTFail("Expected timeout") } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let task = Task.detached { try await NetworkDiagnosticCommand.runStreaming("/bin/sleep", ["5"], timeout: 10) { _ in } }
        try await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testComprehensivePlanIncludesAllDiagnosticsAndPreservesSettings() {
        let plans = NetworkDiagnosticPlan.comprehensive(interfaces: ["en0", "en1"], target: "example.com", port: 8443, resolver: "9.9.9.9", nodes: NetworkDiagnosticNode.defaults)
        XCTAssertEqual(plans.map(\.kind), [.local, .speed, .regional, .dns, .route, .ping, .port, .ipv6, .nodes])
        XCTAssertTrue(plans.allSatisfy { $0.target == "example.com" && $0.port == 8443 && $0.interfaces == ["en0", "en1"] })
        XCTAssertEqual(plans.first { $0.kind == .dns }?.dnsServers.last, "9.9.9.9")
        XCTAssertEqual(plans.reduce(0) { $0 + $1.expectedResultCount }, 107)
    }
    func testComprehensivePlanDoesNotDuplicateResolver() {
        let plans = NetworkDiagnosticPlan.comprehensive(interfaces: [""], target: "example.com", port: 443, resolver: "1.1.1.1", nodes: NetworkDiagnosticNode.defaults)
        XCTAssertEqual(plans.first { $0.kind == .dns }?.dnsServers.filter { $0 == "1.1.1.1" }.count, 1)
    }
    func testTargetsRejectURLsOptionsAndShellText() {
        for valid in ["www.baidu.com", "192.168.1.1", "localhost", "2001:db8::1"] { XCTAssertTrue(NetworkDiagnosticService.validTarget(valid), valid) }
        for invalid in ["", "-n", "https://example.com", "example.com/path", "a b", "x;touch /tmp/a", "a..b", "-bad.example"] { XCTAssertFalse(NetworkDiagnosticService.validTarget(invalid), invalid) }
    }
    func testEndpointValidation() {
        XCTAssertTrue(NetworkDiagnosticService.validEndpoint("https://example.com/down?bytes=4096"))
        XCTAssertTrue(NetworkDiagnosticService.validEndpoint("http://127.0.0.1:8000/down"))
        for invalid in ["ftp://example.com/a", "file:///tmp/a", "https://user:password@example.com", "https://example.com/#x"] { XCTAssertFalse(NetworkDiagnosticService.validEndpoint(invalid)) }
    }
    func testMasksAndSubnetBoundaries() {
        XCTAssertEqual(NetworkDiagnosticService.maskPrefix("255.255.255.0"), 24)
        XCTAssertEqual(NetworkDiagnosticService.maskPrefix("255.255.254.0"), 23)
        XCTAssertEqual(NetworkDiagnosticService.maskPrefix("0.0.0.0"), 0)
        XCTAssertNil(NetworkDiagnosticService.maskPrefix("255.0.255.0"))
        XCTAssertNil(NetworkDiagnosticService.maskPrefix("999.0.0.0"))
        XCTAssertTrue(NetworkDiagnosticService.sameSubnet("192.168.0.1", "192.168.1.254", mask: "255.255.254.0"))
        XCTAssertFalse(NetworkDiagnosticService.sameSubnet("192.168.0.1", "192.168.1.254", mask: "255.255.255.0"))
    }
    func testSubnetWarningsAndVPNException() {
        let entries = [NetworkDiagnosticInterface(name: "en0", address: "192.168.1.2", mask: "255.255.255.0", ipv6: false), .init(name: "en1", address: "192.168.1.3", mask: "255.255.255.0", ipv6: false), .init(name: "en2", address: "169.254.1.2", mask: "255.255.0.0", ipv6: false)]
        let findings = NetworkDiagnosticService.subnetFindings(entries, gateway: "10.0.0.1", routeInterface: "en0")
        XCTAssertTrue(findings.contains { $0.contains("DHCP") })
        XCTAssertTrue(findings.contains { $0.contains("网段重叠") })
        XCTAssertTrue(findings.contains { $0.contains("默认网关") })
        let tunnel = NetworkDiagnosticInterface(name: "utun0", address: "10.0.0.2", mask: "255.255.255.255", ipv6: false)
        XCTAssertTrue(NetworkDiagnosticService.subnetFindings([tunnel], gateway: "10.0.0.1", routeInterface: "utun0").isEmpty)
    }
    func testHealthySubnetAndDuplicateLocalAddress() {
        let entry = NetworkDiagnosticInterface(name: "en0", address: "192.168.1.2", mask: "255.255.255.0", ipv6: false)
        XCTAssertTrue(NetworkDiagnosticService.subnetFindings([entry], gateway: "192.168.1.1", routeInterface: "en0").isEmpty)
        let duplicate = NetworkDiagnosticInterface(name: "en1", address: entry.address, mask: entry.mask, ipv6: false)
        XCTAssertTrue(NetworkDiagnosticService.subnetFindings([entry, duplicate], gateway: nil, routeInterface: nil).contains { $0.contains("相同 IP") })
    }
    func testCommandTimeoutAndCancellation() async throws {
        let timeout = Task.detached { try NetworkDiagnosticCommand.run("/bin/sleep", ["5"], timeout: 0.1) }
        do { _ = try await timeout.value; XCTFail("Expected timeout") } catch { XCTAssertTrue(error.localizedDescription.contains("超时")) }
        let cancelled = Task.detached { try NetworkDiagnosticCommand.run("/bin/sleep", ["5"], timeout: 10) }
        try await Task.sleep(nanoseconds: 100_000_000)
        cancelled.cancel()
        do { _ = try await cancelled.value; XCTFail("Expected cancellation") } catch { XCTAssertTrue(error is CancellationError) }
    }
    func testCommandOutputAndJSONExtraction() throws {
        let result = try NetworkDiagnosticCommand.run("/usr/bin/printf", ["hello"], timeout: 2)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "hello")
        XCTAssertEqual(NetworkDiagnosticService.parseTransfer("curl error\n{\"size_download\":4194304,\"remote_ip\":\"127.0.0.1\"}")?["remote_ip"] as? String, "127.0.0.1")
        XCTAssertNil(NetworkDiagnosticService.parseTransfer("not json"))
    }
    func testDNSMetricsUseAnswersAndReportedResolver() {
        let output = ";; ANSWER SECTION:\nexample.com. 300 IN A 192.0.2.10\n;; Query time: 24 msec\n;; SERVER: 223.5.5.5#53(223.5.5.5)\n"
        let metrics = NetworkDiagnosticService.dnsMetrics(output)
        XCTAssertEqual(metrics.first { $0.name == "A 记录" }?.value, "192.0.2.10")
        XCTAssertEqual(metrics.first { $0.name == "查询耗时" }?.value, "24 msec")
        XCTAssertTrue(NetworkDiagnosticService.dnsMetrics(";; status: NXDOMAIN").isEmpty)
    }
    func testPlotParsersPreserveMissingPingResponses() {
        let output = "64 bytes from 192.0.2.1: icmp_seq=0 ttl=64 time=12.50 ms\nRequest timeout for icmp_seq 1\n64 bytes from 192.0.2.1: icmp_seq=2 ttl=64 time=14.25 ms\n3 packets transmitted, 2 packets received, 33.3% packet loss"
        let points = NetworkDiagnosticPlots.ping(output)
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[0].milliseconds, 12.5)
        XCTAssertNil(points[1].milliseconds)
        XCTAssertEqual(points[2].milliseconds, 14.25)
        XCTAssertEqual(NetworkDiagnosticPlots.packetLoss(output), 33.3)
        XCTAssertTrue(NetworkDiagnosticPlots.ping("cannot resolve host").isEmpty)
    }
    func testPlotRouteGapsAndNumericMetricValidation() {
        let hops = NetworkDiagnosticPlots.route("traceroute to example.com\n 1  192.0.2.1  0.871 ms\n 2  *\n 3  192.0.2.3  12.750 ms\n")
        XCTAssertEqual(hops.map(\.index), [1, 2, 3])
        XCTAssertNil(hops[1].address)
        XCTAssertNil(hops[1].milliseconds)
        XCTAssertEqual(hops[2].milliseconds, 12.75)
        XCTAssertEqual(NetworkDiagnosticPlots.number("24 msec"), 24)
        XCTAssertNil(NetworkDiagnosticPlots.number("未响应"))
        XCTAssertNil(NetworkDiagnosticPlots.number("nan"))
        XCTAssertNil(NetworkDiagnosticPlots.number("—"))
    }
    func testRouteOutputParsing() {
        XCTAssertEqual(NetworkDiagnosticService.field("gateway", in: " route to: default\n gateway: 192.168.1.1\n interface: en0\n"), "192.168.1.1")
    }
}
