import XCTest
@testable import SiphonCore

final class ReachabilityWatchdogTests: XCTestCase {
    func testOneFailureOnlyAsksForConfirmation() {
        var w = ReachabilityWatchdog()
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .confirmSoon)
        XCTAssertFalse(w.suspended)
    }

    func testConsecutiveFailuresSuspend() {
        var w = ReachabilityWatchdog()
        _ = w.probed(reachable: false, proxyOn: true)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .suspend)
        XCTAssertTrue(w.suspended)
    }

    func testASuccessInBetweenResetsTheCount() {
        var w = ReachabilityWatchdog()
        _ = w.probed(reachable: false, proxyOn: true)
        XCTAssertEqual(w.probed(reachable: true, proxyOn: true), .none)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .confirmSoon)
    }

    func testSuspendedResumesOnFirstSuccess() {
        var w = ReachabilityWatchdog(suspended: true)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: false), .none, "still down: stay suspended")
        XCTAssertTrue(w.suspended)
        XCTAssertEqual(w.probed(reachable: true, proxyOn: false), .resume)
        XCTAssertFalse(w.suspended)
    }

    /// A switch the user turned off is never turned on by the watchdog.
    func testOffByTheUserStaysOff() {
        var w = ReachabilityWatchdog()
        XCTAssertEqual(w.probed(reachable: false, proxyOn: false), .none)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: false), .none)
        XCTAssertEqual(w.probed(reachable: true, proxyOn: false), .none)
    }

    func testTheUserTurningItOnEndsASuspension() {
        var w = ReachabilityWatchdog(suspended: true)
        w.userSet(on: true, serverKnownUnreachable: false)
        XCTAssertFalse(w.suspended)
        w = ReachabilityWatchdog(suspended: true)
        w.userSet(on: false, serverKnownUnreachable: true)
        XCTAssertFalse(w.suspended)
        XCTAssertEqual(w.probed(reachable: true, proxyOn: false), .none, "user turned it off: no resume")
    }

    /// Forcing it on against a known-dead server is respected, not undone
    /// two probes later...
    func testForcingOnWhileUnreachableIsRespected() {
        var w = ReachabilityWatchdog()
        w.userSet(on: true, serverKnownUnreachable: true)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .none)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .none)
        XCTAssertFalse(w.suspended)
    }

    /// ...until the network changes,
    func testTheOverrideEndsWithTheNetwork() {
        var w = ReachabilityWatchdog()
        w.userSet(on: true, serverKnownUnreachable: true)
        w.networkChanged()
        _ = w.probed(reachable: false, proxyOn: true)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .suspend)
    }

    /// ...or the server is seen answering, after which normal rules apply.
    func testTheOverrideEndsWhenTheServerAnswers() {
        var w = ReachabilityWatchdog()
        w.userSet(on: true, serverKnownUnreachable: true)
        _ = w.probed(reachable: true, proxyOn: true)
        _ = w.probed(reachable: false, proxyOn: true)
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .suspend)
    }

    /// Selecting another server while suspended keeps the suspension, so the
    /// new one goes into force the moment it answers.
    func testASuspensionSurvivesSelectingAnotherServer() {
        var w = ReachabilityWatchdog(suspended: true)
        w.serverChanged()
        XCTAssertTrue(w.suspended)
        XCTAssertEqual(w.probed(reachable: true, proxyOn: false), .resume)
    }

    func testSelectingAnotherServerRestartsTheCount() {
        var w = ReachabilityWatchdog()
        _ = w.probed(reachable: false, proxyOn: true)
        w.serverChanged()
        XCTAssertEqual(w.probed(reachable: false, proxyOn: true), .confirmSoon)
    }

    func testResetForgetsEverything() {
        var w = ReachabilityWatchdog(suspended: true)
        w.reset()
        XCTAssertEqual(w, ReachabilityWatchdog())
    }
}
