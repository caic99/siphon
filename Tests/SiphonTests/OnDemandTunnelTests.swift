import XCTest
@testable import SiphonCore

/// Tunnels run ssh only while traffic wants them.
final class OnDemandTunnelTests: XCTestCase {
    private var fakeSSH: String { TestServers.fixtures.appendingPathComponent("fake-ssh.sh").path }
    private var suite = ""; private var defaults: UserDefaults!
    private var manager: TunnelManager?; private var procs: [Process] = []

    override func setUp() { suite = "siphon.tests.\(UUID().uuidString)"; defaults = UserDefaults(suiteName: suite) }
    override func tearDown() {
        manager?.stopAll(); procs.forEach { if $0.isRunning { $0.terminate() } }
        defaults.removePersistentDomain(forName: suite)
    }
    private func wait(_ seconds: TimeInterval = 10, for predicate: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline { if predicate() { return true }; RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        return predicate()
    }
    private func make() -> TunnelManager {
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        m.httpBasePort = TestServers.freePort(); m.socksBasePort = TestServers.freePort()
        manager = m; return m
    }

    /// Enabling a tunnel must not start ssh. The bridge listens; ssh does not run.
    func testEnabledTunnelIsDormantUntilUsed() {
        let m = make()
        let config = m.add(target: "good-host")
        XCTAssertTrue(wait { m.state(of: config.id) == .dormant }, "\(m.state(of: config.id))")
        XCTAssertTrue(wait { m.proxyServer(for: config.id) != nil }, "bridge should listen while dormant")
        Thread.sleep(forTimeInterval: 1.5)
        XCTAssertEqual(m.state(of: config.id), .dormant)
        XCTAssertFalse(TestServers.waitForPort(config.socksPort, seconds: 0.2), "ssh must not be running")
    }

    /// The first request wakes the tunnel and is served -- not refused with 503.
    func testFirstRequestWakesTheTunnelAndSucceeds() {
        let m = make()
        let config = m.add(target: "good-host")
        XCTAssertTrue(wait { m.proxyServer(for: config.id) != nil })
        let origin = TestServers.freePort(); procs.append(TestServers.originServer(port: origin))
        XCTAssertTrue(TestServers.waitForPort(origin))
        let (status, body) = TestServers.curl(["-x", "http://127.0.0.1:\(config.httpPort)", "http://127.0.0.1:\(origin)/hello.txt"])
        XCTAssertEqual(status, 0); XCTAssertEqual(body, "hello through the tunnel\n")
        XCTAssertEqual(m.state(of: config.id), .connected)
    }

    /// With no traffic for idleTimeout, ssh is stopped and the tunnel sleeps;
    /// traffic resets the clock; a later request wakes it again.
    func testIdleTunnelGoesDormantAndWakesAgain() {
        let m = make()
        m.idleTimeout = 1.5
        let config = m.add(target: "good-host")
        m.connect(config.id)
        XCTAssertTrue(wait { m.state(of: config.id) == .connected })
        // Keep it busy past one timeout window.
        let origin = TestServers.freePort(); procs.append(TestServers.originServer(port: origin))
        XCTAssertTrue(TestServers.waitForPort(origin))
        for _ in 0..<4 { _ = TestServers.curl(["-x", "http://127.0.0.1:\(config.httpPort)", "http://127.0.0.1:\(origin)/hello.txt"]); Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertEqual(m.state(of: config.id), .connected, "traffic must keep it awake")
        // Now leave it alone.
        XCTAssertTrue(wait(6) { m.state(of: config.id) == .dormant }, "\(m.state(of: config.id))")
        XCTAssertTrue(wait(3) { !TestServers.waitForPort(config.socksPort, seconds: 0.2) }, "ssh should be gone")
        let (status, _) = TestServers.curl(["-x", "http://127.0.0.1:\(config.httpPort)", "http://127.0.0.1:\(origin)/hello.txt"])
        XCTAssertEqual(status, 0, "a request after sleeping must wake it")
        XCTAssertEqual(m.state(of: config.id), .connected)
    }

    /// A network change must not wake a sleeping tunnel.
    func testNetworkChangeLeavesDormantTunnelsAsleep() {
        let m = make()
        let config = m.add(target: "good-host")
        XCTAssertTrue(wait { m.state(of: config.id) == .dormant })
        m.networkChanged()
        Thread.sleep(forTimeInterval: 1.0)
        XCTAssertEqual(m.state(of: config.id), .dormant)
    }

    /// A request to a tunnel that cannot connect still gets a clean 503, after
    /// the attempt, rather than hanging.
    func testRequestToAFailingTunnelGets503() {
        let m = make()
        let config = m.add(target: "fail-host")
        XCTAssertTrue(wait { m.proxyServer(for: config.id) != nil })
        let (_, code) = TestServers.curl(["-m", "60", "-o", "/dev/null", "-w", "%{http_code}",
                                          "-x", "http://127.0.0.1:\(config.httpPort)", "http://127.0.0.1:1/"])
        XCTAssertEqual(code, "503")
    }
}
