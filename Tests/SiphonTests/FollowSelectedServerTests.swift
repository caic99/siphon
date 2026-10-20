import XCTest
@testable import SiphonCore

/// The controller end to end: probe results in, switch position and privileged
/// writes out. The runner only records — nothing here runs sudo, osascript or
/// touches this Mac's proxy settings. The network state it reads is real.
final class FollowSelectedServerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!
    private var controller: ProxyController!
    private var reachable = false
    private var ran: [(String, [String])] = []
    private let server = ProxyServer(host: "proxy.example.test", port: 3128)

    override func setUp() {
        suite = "com.chucai.siphon.tests.follow.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        reachable = false
        ran = []
    }

    override func tearDown() {
        controller?.shutdown()
        controller = nil
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeController() -> ProxyController {
        let runner = PrivilegeRunner { [unowned self] path, args, _ in
            self.ran.append((path, args))
            return (0, "")   // every probe "allowed", every write "succeeded"
        }
        let c = ProxyController(defaults: defaults, runner: runner, discoversServers: false,
                                reachabilityProber: { [unowned self] _, _, done in
            done(self.reachable ? .reachable(latency: 0.001) : .unreachable("connection refused"))
        })
        c.watchInterval = 0.2
        c.suspendedWatchInterval = 0.2
        c.confirmDelay = 0.1
        return c
    }

    /// Selected and switched on before start, as after a previous session.
    private func startOn() {
        controller = makeController()
        controller.select(server)
        controller.setOn(true)
        controller.start()
    }

    private func wait(_ what: String, timeout: TimeInterval = 3, until condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        XCTAssertTrue(condition(), "timed out waiting for: \(what)")
    }

    func testAnUnreachableServerPausesTheProxyAndItsReturnResumesIt() {
        startOn()
        wait("pause") { controller.isSuspendedForUnreachableServer }
        XCTAssertFalse(controller.desiredOn)

        reachable = true
        wait("resume") { controller.desiredOn }
        XCTAssertFalse(controller.isSuspendedForUnreachableServer)
    }

    func testNoWriteEverAsksForAPassword() {
        startOn()
        wait("pause") { controller.isSuspendedForUnreachableServer }
        reachable = true
        wait("resume") { controller.desiredOn }
        XCTAssertFalse(ran.contains { $0.0.hasSuffix("osascript") }, "automatic writes must never prompt")
        XCTAssertTrue(ran.allSatisfy { $0.0 == "/usr/bin/sudo" && $0.1.first == "-n" })
    }

    func testAPauseSurvivesARelaunch() {
        startOn()
        wait("pause") { controller.isSuspendedForUnreachableServer }
        controller.shutdown()

        controller = makeController()
        XCTAssertTrue(controller.isSuspendedForUnreachableServer, "the pause is persisted")
        reachable = true
        controller.start()
        wait("resume after relaunch") { controller.desiredOn }
    }

    /// The user turning it on against a dead server is not undone.
    func testTurningItOnWhileKnownUnreachableIsRespected() {
        startOn()
        wait("pause") { controller.isSuspendedForUnreachableServer }
        controller.setOn(true)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(controller.desiredOn)
        XCTAssertFalse(controller.isSuspendedForUnreachableServer)
    }

    /// Off by the user stays off, whatever the server does.
    func testOffByTheUserIsNotTurnedOn() {
        reachable = true
        startOn()
        controller.setOn(false)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(controller.desiredOn)
    }

    /// Without auto re-apply nothing is followed at all.
    func testNothingHappensWithAutoReapplyOff() {
        controller = makeController()
        controller.reapplyOnNetworkChange = false
        controller.select(server)
        controller.setOn(true)
        controller.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(controller.desiredOn)
        XCTAssertFalse(controller.isSuspendedForUnreachableServer)
    }

    /// Unchecking auto re-apply ends a pause but leaves the proxy off: the
    /// server is still unreachable.
    func testTurningAutoOffEndsAPauseWithoutTurningItOn() {
        startOn()
        wait("pause") { controller.isSuspendedForUnreachableServer }
        controller.reapplyOnNetworkChange = false
        XCTAssertFalse(controller.isSuspendedForUnreachableServer)
        reachable = true
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(controller.desiredOn)
    }
}
