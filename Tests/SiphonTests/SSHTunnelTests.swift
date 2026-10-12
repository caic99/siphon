import XCTest
@testable import SiphonCore

/// SSHTunnel against a stand-in `ssh` that really serves SOCKS5 on the -D port,
/// so readiness, failure reporting, give-up and restart are all exercised with
/// no network and no remote host.
final class SSHTunnelTests: XCTestCase {
    private var fakeSSH: String { TestServers.fixtures.appendingPathComponent("fake-ssh.sh").path }
    private var tunnels: [SSHTunnel] = []

    override func tearDown() { tunnels.forEach { $0.stop() }; tunnels.removeAll() }

    private func make(_ target: String) -> SSHTunnel {
        let t = SSHTunnel(target: target, socksPort: TestServers.freePort(), sshPath: fakeSSH)
        t.reconnectDelay = 0.2
        tunnels.append(t)
        return t
    }

    @discardableResult
    private func wait(_ seconds: TimeInterval = 8, for predicate: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    func testCommandLineIsWhatTunnelmuxUsedMinusHostKeyBypass() {
        let t = SSHTunnel(target: "host.example", socksPort: 18081)
        let args = t.arguments
        XCTAssertEqual(args.first, "-N")
        XCTAssertTrue(args.contains("127.0.0.1:18081"))
        XCTAssertTrue(args.contains("BatchMode=yes"))
        XCTAssertTrue(args.contains("ExitOnForwardFailure=yes"))
        XCTAssertTrue(args.contains("ServerAliveInterval=10"))
        XCTAssertEqual(args.last, "host.example")
        // Deliberately not ported: host-key verification stays on.
        XCTAssertFalse(args.contains { $0.contains("StrictHostKeyChecking") || $0.contains("UserKnownHostsFile") })
    }

    func testBecomesConnectedWhenThePortOpensAndIdleWhenStopped() {
        let t = make("good-host")
        t.start()
        XCTAssertTrue(wait { t.state == .connected }, "state: \(t.state)")
        XCTAssertNotNil(t.connectedSince)
        XCTAssertTrue(TestServers.waitForPort(t.socksPort, seconds: 1))
        t.stop()
        XCTAssertTrue(wait { t.state == .idle })
        // The ssh child went with it.
        XCTAssertTrue(wait(3) { !TestServers.waitForPort(t.socksPort, seconds: 0.2) })
    }

    func testFailureCarriesSSHsOwnWordsThenGivesUp() {
        let t = make("fail-host")
        t.start()
        XCTAssertTrue(wait { if case .reconnecting = t.state { return true }; return false }, "state: \(t.state)")
        if case .reconnecting(let reason, let attempt) = t.state {
            XCTAssertTrue(reason.contains("No route to host"), reason)
            XCTAssertEqual(attempt, 1)
        }
        XCTAssertTrue(wait { if case .gaveUp = t.state { return true }; return false }, "state: \(t.state)")
        // retry() starts the count over.
        t.retry()
        XCTAssertTrue(wait { if case .reconnecting(_, let n) = t.state { return n == 1 }; return false })
    }

    func testReadinessTimeoutIsAFailure() {
        let t = make("slow-host")
        t.connectTimeout = 1
        t.start()
        XCTAssertTrue(wait(5) { if case .reconnecting(let r, _) = t.state { return r.contains("did not open") }; return false },
                      "state: \(t.state)")
    }

    /// What Quit relies on: by the time stopNow() returns, SIGTERM has reached
    /// the child, so an exit() right after cannot leave it behind.
    func testStopNowSignalsTheChildBeforeReturning() {
        let t = make("good-host")
        t.start()
        XCTAssertTrue(wait { t.state == .connected })
        t.stopNow()
        XCTAssertEqual(t.state, .idle)
        // The fake ssh is a python process; SIGTERM ends it within a moment.
        XCTAssertTrue(wait(2) { !TestServers.waitForPort(t.socksPort, seconds: 0.1) },
                      "child still listening after stopNow returned")
    }

    func testRestartComesBackConnected() {
        let t = make("good-host")
        t.start()
        XCTAssertTrue(wait { t.state == .connected })
        let first = t.connectedSince
        t.restart()
        XCTAssertTrue(wait { t.state == .connecting || t.connectedSince != first })
        XCTAssertTrue(wait { t.state == .connected && t.connectedSince != first }, "state: \(t.state)")
    }
}
