import XCTest
@testable import AILockCore

final class NetworkFilterTests: XCTestCase {
    let app = SignedApplicationIdentity(identifier: "com.example.client", teamID: "ABCDE12345")
    func testApplicationIdentityRequiresBothIdentifierAndTeam() throws {
        let policy = try NetworkFilterPolicy(applications: [.init(application: app, host: nil)]).validated()
        XCTAssertTrue(policy.blocks(host: nil, application: app))
        XCTAssertFalse(policy.blocks(host: "example.com", application: .init(identifier: app.identifier, teamID: "OTHER12345")))
        XCTAssertFalse(policy.blocks(host: "example.com", application: nil))
    }
    func testGlobalAndApplicationHostRulesHaveSeparateScope() throws {
        let policy = try NetworkFilterPolicy(blockedHosts: ["GLOBAL.COM."], applications: [.init(application: app, host: " Scoped.COM ")]).validated()
        XCTAssertTrue(policy.blocks(host: "global.com", application: nil))
        XCTAssertTrue(policy.blocks(host: "scoped.com", application: app))
        XCTAssertFalse(policy.blocks(host: "other.com", application: app))
        XCTAssertFalse(policy.blocks(host: nil, application: app))
        XCTAssertFalse(policy.blocks(host: "scoped.com", application: nil))
    }
    func testPolicyRoundtripDeduplicationAndBounds() throws {
        let rule = ApplicationBlockRule(application: app, host: "EXAMPLE.COM.")
        let policy = try NetworkFilterPolicy(applications: [rule, rule], automaticallyRecover: true).validated()
        XCTAssertEqual(policy.applications.count, 1)
        XCTAssertEqual(try NetworkFilterPolicy.decoded(policy.encoded()), policy)
        XCTAssertThrowsError(try NetworkFilterPolicy(applications: Array(repeating: rule, count: 129)).validated())
        XCTAssertThrowsError(try NetworkFilterPolicy.decoded(Data(repeating: 0, count: 128 * 1024 + 1)))
        XCTAssertThrowsError(try NetworkFilterPolicy(revision: "invalid").validated())
        XCTAssertThrowsError(try NetworkFilterPolicy(applications: [.init(application: app, host: "*.example.com")]).validated())
        XCTAssertThrowsError(try SignedApplicationIdentity(identifier: "spoof/client", teamID: app.teamID).validated())
    }
    func testRecoveryDefaultPreservesBlockingEvenAfterRepeatedFaults() {
        var machine = FilterHealthStateMachine()
        for _ in 0..<100 { XCTAssertNotEqual(machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: false), .disableFilter) }
        XCTAssertEqual(machine.failures, 3)
    }
    func testOptedInRecoveryRequiresThreeFaultsAndOnlyTriggersOnce() {
        var machine = FilterHealthStateMachine()
        XCTAssertEqual(machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: true), .reconnect)
        XCTAssertEqual(machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: true), .reconnect)
        XCTAssertEqual(machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: true), .disableFilter)
        XCTAssertEqual(machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: true), .none)
    }
    func testOfflineSleepAndHealthyHeartbeatBreakFailureStreak() {
        for condition in 0..<3 {
            var machine = FilterHealthStateMachine()
            for _ in 0..<2 { _ = machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: true) }
            XCTAssertEqual(machine.observe(healthy: condition == 2, networkAvailable: condition != 0, suspended: condition == 1, automaticallyRecover: true), .none)
            XCTAssertEqual(machine.failures, 0)
            XCTAssertEqual(machine.observe(healthy: false, networkAvailable: true, suspended: false, automaticallyRecover: true), .reconnect)
        }
    }
    func testProviderLeaseAllowsOnlyOptedInBypassAndRenews() {
        var lease = FilterRecoveryLease(now: 100, automaticallyRecover: false)
        XCTAssertFalse(lease.shouldBypass(now: 1000))
        lease = FilterRecoveryLease(now: 100, automaticallyRecover: true)
        XCTAssertFalse(lease.shouldBypass(now: 129))
        XCTAssertTrue(lease.shouldBypass(now: 130))
        lease.renew(now: 131)
        XCTAssertFalse(lease.shouldBypass(now: 140))
        XCTAssertTrue(lease.shouldBypass(now: 161))
    }
    func testMonotonicClockRollbackDoesNotReleaseRules() {
        var lease = FilterRecoveryLease(now: 100, automaticallyRecover: true)
        XCTAssertFalse(lease.shouldBypass(now: 1))
        XCTAssertFalse(lease.shouldBypass(now: 30))
        XCTAssertTrue(lease.shouldBypass(now: 31))
    }
}
