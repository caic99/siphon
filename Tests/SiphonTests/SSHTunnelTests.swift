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

    /// The supervisor must take ssh down when the app does -- including the
    /// ways that skip applicationWillTerminate. Simulated by closing the pipe
    /// the app would hold, exactly what the kernel does when it dies.
    func testSSHDiesWhenTheLeashCloses() {
        let port = TestServers.freePort()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", SSHTunnel.supervisorScript, "test", fakeSSH, "-N", "-D", "127.0.0.1:\(port)", "good-host"]
        let leash = Pipe()
        p.standardInput = leash
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()
        XCTAssertTrue(TestServers.waitForPort(port, seconds: 8), "fake ssh never listened")
        try! leash.fileHandleForWriting.close()
        XCTAssertTrue(wait(5) { !p.isRunning }, "supervisor still running after its stdin closed")
        XCTAssertFalse(TestServers.waitForPort(port, seconds: 1), "ssh outlived its supervisor")
    }

    /// And when ssh itself dies, the supervisor exits with ssh's status so the
    /// tunnel notices.
    func testSupervisorPassesThroughSSHsExitStatus() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", SSHTunnel.supervisorScript, "test", fakeSSH, "-N", "-D", "127.0.0.1:1", "fail-host"]
        p.standardInput = Pipe()
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()
        p.waitUntilExit()
        XCTAssertEqual(p.terminationStatus, 255)
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
