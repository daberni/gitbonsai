import XCTest
@testable import GitEngine

final class AutoFetchPolicyTests: XCTestCase {
    let start = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let offline = "fatal: unable to access 'https://example.com/r.git/': Could not resolve host: example.com"
    let denied = "git@example.com: Permission denied (publickey).\nfatal: Could not read from remote repository."

    func policy(interval minutes: Double? = 10) -> AutoFetchPolicy {
        AutoFetchPolicy(fetchOnActivation: true, interval: minutes.map { $0 * 60 })
    }

    func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    func testActivationFetchesOnlyOncePerThreshold() {
        var policy = policy()
        XCTAssert(policy.skip(.activation, now: at(0), lastFetch: nil, power: .adapter) == nil)
        policy.started(at: at(0))
        policy.finished(failure: nil)
        XCTAssert(policy.skip(.activation, now: at(1), lastFetch: at(0), power: .adapter) == .recent)
        XCTAssert(policy.skip(.activation, now: at(4.9), lastFetch: at(0), power: .adapter) == .recent)
        XCTAssert(policy.skip(.activation, now: at(5), lastFetch: at(0), power: .adapter) == nil)
    }

    func testManualFetchCountsAsRecent() {
        let policy = policy()
        XCTAssert(policy.skip(.activation, now: at(10), lastFetch: at(8), power: .adapter) == .recent)
        XCTAssert(policy.skip(.interval, now: at(10), lastFetch: at(8), power: .adapter) == .recent)
    }

    func testFailedAttemptDoesNotRetryOnEveryActivation() {
        var policy = policy()
        policy.started(at: at(0))
        policy.finished(failure: denied)
        XCTAssert(policy.skip(.activation, now: at(2), lastFetch: nil, power: .adapter) == .recent)
        XCTAssert(policy.skip(.activation, now: at(6), lastFetch: nil, power: .adapter) == nil)
    }

    func testActivationCanBeTurnedOff() {
        var policy = policy()
        policy.fetchOnActivation = false
        XCTAssert(policy.skip(.activation, now: at(0), lastFetch: nil, power: .adapter) == .disabled)
        XCTAssert(policy.skip(.interval, now: at(0), lastFetch: nil, power: .adapter) == nil)
    }

    func testIntervalFollowsSettingAndPower() {
        XCTAssert(policy(interval: nil).skip(.interval, now: at(60), lastFetch: at(0), power: .adapter) == .disabled)
        let policy = policy()
        XCTAssert(policy.skip(.interval, now: at(9), lastFetch: at(0), power: .adapter) == .recent)
        XCTAssert(policy.skip(.interval, now: at(10), lastFetch: at(0), power: .adapter) == nil)
        XCTAssert(policy.skip(.interval, now: at(10), lastFetch: at(0), power: .battery) == .recent)
        XCTAssert(policy.skip(.interval, now: at(20), lastFetch: at(0), power: .battery) == nil)
        XCTAssert(policy.skip(.interval, now: at(60), lastFetch: at(0), power: .lowPower) == .lowPower)
        XCTAssert(policy.skip(.activation, now: at(60), lastFetch: at(0), power: .lowPower) == nil)
    }

    func testFailuresBackOffAndSuccessResets() {
        var policy = policy()
        policy.started(at: at(0))
        policy.finished(failure: denied)
        XCTAssert(!policy.isOffline)
        XCTAssert(policy.skip(.interval, now: at(15), lastFetch: nil, power: .adapter) == .backingOff)
        XCTAssert(policy.skip(.interval, now: at(20), lastFetch: nil, power: .adapter) == nil)
        policy.started(at: at(20))
        policy.finished(failure: denied)
        XCTAssert(policy.skip(.interval, now: at(55), lastFetch: nil, power: .adapter) == .backingOff)
        XCTAssert(policy.skip(.interval, now: at(60), lastFetch: nil, power: .adapter) == nil)
        for minute in [60.0, 140, 220] {
            policy.started(at: at(minute))
            policy.finished(failure: denied)
        }
        // Capped at eight times the interval.
        XCTAssert(policy.skip(.interval, now: at(300), lastFetch: nil, power: .adapter) == nil)
        policy.started(at: at(300))
        policy.finished(failure: nil)
        XCTAssert(policy.failures == 0)
        XCTAssert(policy.skip(.interval, now: at(310), lastFetch: at(300), power: .adapter) == nil)
    }

    func testOfflineWaitsForTheNextActivation() {
        var policy = policy()
        policy.started(at: at(0))
        policy.finished(failure: offline)
        XCTAssert(policy.isOffline)
        XCTAssert(policy.skip(.interval, now: at(500), lastFetch: nil, power: .adapter) == .offline)
        XCTAssert(policy.skip(.activation, now: at(6), lastFetch: nil, power: .adapter) == nil)
        policy.started(at: at(6))
        policy.finished(failure: nil)
        XCTAssert(policy.skip(.interval, now: at(16), lastFetch: at(6), power: .adapter) == nil)
    }

    func testSituationSkips() {
        XCTAssert(AutoFetchPolicy.skip(.init(hasRemote: true, operationInProgress: false, fetchRunning: false)) == nil)
        XCTAssert(AutoFetchPolicy.skip(.init(hasRemote: false, operationInProgress: false, fetchRunning: false)) == .noRemote)
        XCTAssert(AutoFetchPolicy.skip(.init(hasRemote: true, operationInProgress: true, fetchRunning: false)) == .operationInProgress)
        XCTAssert(AutoFetchPolicy.skip(.init(hasRemote: true, operationInProgress: false, fetchRunning: true)) == .fetchRunning)
    }

    func testNetworkFailuresAreToldApart() {
        XCTAssert(AutoFetchPolicy.isNetworkFailure(offline))
        XCTAssert(AutoFetchPolicy.isNetworkFailure("ssh: connect to host example.com port 22: Network is unreachable"))
        XCTAssert(AutoFetchPolicy.isNetworkFailure("fatal: unable to access 'https://h/': Failed to connect to h port 443 after 3 ms: Couldn't connect to server"))
        XCTAssert(!AutoFetchPolicy.isNetworkFailure(denied))
        XCTAssert(!AutoFetchPolicy.isNetworkFailure("fatal: '/tmp/gone.git' does not appear to be a git repository"))
    }

    func testUntouchedIntervalGetsTheNewDefault() {
        XCTAssert(AutoFetchPolicy.intervalMinutes(stored: nil) == 10)
        XCTAssert(AutoFetchPolicy.intervalMinutes(stored: 0) == 0)
        XCTAssert(AutoFetchPolicy.intervalMinutes(stored: 30) == 30)
    }
}
