import XCTest
@testable import SiphonCore

final class TunnelManagerTests: XCTestCase {
    private var fakeSSH: String { TestServers.fixtures.appendingPathComponent("fake-ssh.sh").path }
    private var suite = ""
    private var defaults: UserDefaults!
    private var manager: TunnelManager?
    private var procs: [Process] = []

    override func setUp() {
        suite = "siphon.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }
    override func tearDown() {
        manager?.stopAll()
        procs.forEach { if $0.isRunning { $0.terminate() } }
        defaults.removePersistentDomain(forName: suite)
    }

    private func wait(_ seconds: TimeInterval = 10, for predicate: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if predicate() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return predicate()
    }

    func testAddingATunnelBringsUpTheBridgeAndTrafficFlows() {
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.httpPort = TestServers.freePort()
        m.socksBasePort = TestServers.freePort()
        XCTAssertNil(m.proxyServer, "no bridge before any tunnel exists")

        let config = m.add(target: "good-host")
        XCTAssertEqual(config.socksPort, m.socksBasePort)
        XCTAssertTrue(wait { m.state(of: config.id) == .connected }, "\(m.state(of: config.id))")
        XCTAssertTrue(wait { m.proxyServer != nil }, "bridge never listened: \(m.bridgeError ?? "-")")
        XCTAssertEqual(m.proxyServer, ProxyServer(host: "127.0.0.1", port: Int(m.httpPort)))
        XCTAssertTrue(m.isTunnelProxy(m.proxyServer))

        // End to end: curl -> bridge -> fake ssh's SOCKS -> origin.
        let originPort = TestServers.freePort()
        procs.append(TestServers.originServer(port: originPort))
        XCTAssertTrue(TestServers.waitForPort(originPort))
        let (status, body) = TestServers.curl(["-x", "http://127.0.0.1:\(m.httpPort)", "http://127.0.0.1:\(originPort)/hello.txt"])
        XCTAssertEqual(status, 0); XCTAssertEqual(body, "hello through the tunnel\n")

        // Second tunnel gets the next port; removing the last enabled one
        // takes the bridge down.
        let second = m.add(target: "good-host")
        XCTAssertGreaterThan(second.socksPort, config.socksPort)
        m.remove(config.id); m.remove(second.id)
        XCTAssertTrue(wait { m.proxyServer == nil })
        XCTAssertEqual(m.configs.count, 0)
    }

    func testConfigurationPersistsAndRelaunchesOnStart() {
        let first = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        first.httpPort = TestServers.freePort()
        first.socksBasePort = TestServers.freePort()
        let config = first.add(target: "good-host")
        first.setEnabled(config.id, false)
        XCTAssertEqual(first.enabledCount, 0)
        first.stopAll()

        let second = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = second
        XCTAssertEqual(second.configs, first.configs)
        XCTAssertEqual(second.httpPort, first.httpPort)
        second.start()
        XCTAssertNil(second.proxyServer, "disabled tunnels must not start")
        second.setEnabled(config.id, true)
        XCTAssertTrue(wait { second.state(of: config.id) == .connected })
    }

    /// A port something else is listening on must be skipped, or the readiness
    /// probe would mistake the other listener for our tunnel.
    func testAllocationSkipsPortsInUse() {
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.httpPort = TestServers.freePort()
        let base = TestServers.freePort()
        m.socksBasePort = base
        procs.append(TestServers.python("socks5-server.py", [String(base)]))   // squatter
        XCTAssertTrue(TestServers.waitForPort(base))
        let config = m.add(target: "good-host")
        XCTAssertNotEqual(config.socksPort, base)
        XCTAssertTrue(wait { m.state(of: config.id) == .connected })
    }

    func testAllGaveUpOnlyWhenEveryEnabledTunnelHas() {
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.httpPort = TestServers.freePort()
        m.socksBasePort = TestServers.freePort()
        let bad = m.add(target: "fail-host")
        XCTAssertFalse(m.allGaveUp, "still retrying")
        // Real retry pacing is 8 s x 3; waiting that out here proves the
        // real cadence rather than a shortened one.
        XCTAssertTrue(wait(40) { m.allGaveUp }, "\(m.state(of: bad.id))")
        let good = m.add(target: "good-host")
        XCTAssertTrue(wait { m.state(of: good.id) == .connected })
        XCTAssertFalse(m.allGaveUp)
    }
}
