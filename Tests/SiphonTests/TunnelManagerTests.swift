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
        m.httpBasePort = TestServers.freePort()
        m.socksBasePort = TestServers.freePort()
        let config = m.add(target: "good-host")
        XCTAssertEqual(config.socksPort, m.socksBasePort)
        XCTAssertEqual(config.httpPort, m.httpBasePort)
        m.connect(config.id)
        XCTAssertTrue(wait { m.state(of: config.id) == .connected }, "\(m.state(of: config.id))")
        XCTAssertTrue(wait { m.proxyServer(for: config.id) != nil },
                      "bridge never listened: \(m.bridgeError(for: config.id) ?? "-")")
        XCTAssertEqual(m.proxyServer(for: config.id), m.proxyAddress(for: config))
        XCTAssertEqual(m.tunnel(forProxy: m.proxyAddress(for: config))?.id, config.id)

        // End to end: curl -> this tunnel's bridge -> its SOCKS -> origin.
        let originPort = TestServers.freePort()
        procs.append(TestServers.originServer(port: originPort))
        XCTAssertTrue(TestServers.waitForPort(originPort))
        let (status, body) = TestServers.curl(["-x", "http://127.0.0.1:\(config.httpPort)", "http://127.0.0.1:\(originPort)/hello.txt"])
        XCTAssertEqual(status, 0); XCTAssertEqual(body, "hello through the tunnel\n")

        // A second tunnel is a second, separate proxy on its own ports.
        let second = m.add(target: "good-host")
        XCTAssertGreaterThan(second.socksPort, config.socksPort)
        XCTAssertGreaterThan(second.httpPort, config.httpPort)
        m.connect(second.id)
        XCTAssertTrue(wait { m.proxyServer(for: second.id) != nil })

        // Removing one takes only its own bridge down.
        m.remove(config.id)
        XCTAssertTrue(wait { !TestServers.waitForPort(config.httpPort, seconds: 0.2) })
        XCTAssertNotNil(m.proxyServer(for: second.id))
        m.remove(second.id)
        XCTAssertEqual(m.configs.count, 0)
    }

    func testConfigurationPersistsAndRelaunchesOnStart() {
        let first = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        first.httpBasePort = TestServers.freePort()
        first.socksBasePort = TestServers.freePort()
        let config = first.add(target: "good-host")
        first.setEnabled(config.id, false)
        XCTAssertEqual(first.enabledCount, 0)
        first.stopAll()

        let second = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = second
        XCTAssertEqual(second.configs, first.configs)
        second.start()
        XCTAssertNil(second.proxyServer(for: config.id), "disabled tunnels must not start")
        second.setEnabled(config.id, true)
        second.connect(config.id)
        XCTAssertTrue(wait { second.state(of: config.id) == .connected })
    }

    /// A port something else is listening on must be skipped, or the readiness
    /// probe would mistake the other listener for our tunnel.
    func testAllocationSkipsPortsInUse() {
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.httpBasePort = TestServers.freePort()
        let base = TestServers.freePort()
        m.socksBasePort = base
        procs.append(TestServers.python("socks5-server.py", [String(base)]))   // squatter
        XCTAssertTrue(TestServers.waitForPort(base))
        let config = m.add(target: "good-host")
        XCTAssertNotEqual(config.socksPort, base)
        m.connect(config.id)
        XCTAssertTrue(wait { m.state(of: config.id) == .connected })
    }

    /// A child left behind by a dead instance is stopped at the next start --
    /// but only if its command line still shows our port, so a recycled PID
    /// belonging to something else is left alone.
    func testLeftoverChildrenAreReapedAtStart() {
        let port = TestServers.freePort()
        // Stand-in for an orphaned `ssh -N -D 127.0.0.1:<port>`. The real ssh
        // keeps its arguments in its command line, which is what the registry
        // matches on; fake-ssh.sh execs python and loses them, so run the
        // SOCKS server directly with the marker as extra (ignored) arguments.
        let orphan = Process()
        orphan.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        orphan.arguments = [TestServers.fixtures.appendingPathComponent("socks5-server.py").path,
                            String(port), "-N", "-D", "127.0.0.1:\(port)"]
        orphan.standardOutput = FileHandle.nullDevice; orphan.standardError = FileHandle.nullDevice
        try! orphan.run()
        procs.append(orphan)
        XCTAssertTrue(TestServers.waitForPort(port))
        ChildRegistry(defaults: defaults).record(pid: orphan.processIdentifier, socksPort: port)

        // An unrelated live process recorded under a port it does not serve.
        let bystander = Process()
        bystander.executableURL = URL(fileURLWithPath: "/bin/sleep"); bystander.arguments = ["30"]
        try! bystander.run(); procs.append(bystander)
        ChildRegistry(defaults: defaults).record(pid: bystander.processIdentifier, socksPort: 1)

        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.start()
        XCTAssertTrue(wait(5) { !orphan.isRunning }, "orphan should have been reaped")
        XCTAssertTrue(bystander.isRunning, "a process whose command line doesn't match must be left alone")
    }

    /// The SOCKS port kept from last time has been taken in the meantime: the
    /// tunnel must move rather than fail to bind -- or, worse, report the
    /// stranger's listener as connected.
    func testPersistedSOCKSPortTakenAtRelaunchIsReassigned() {
        let first = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        first.httpBasePort = TestServers.freePort()
        first.socksBasePort = TestServers.freePort()
        let config = first.add(target: "good-host")
        first.connect(config.id)
        XCTAssertTrue(wait { first.state(of: config.id) == .connected })
        first.stopAll()
        XCTAssertTrue(wait(3) { !TestServers.waitForPort(config.socksPort, seconds: 0.2) })

        // Something else takes the port before the next launch.
        procs.append(TestServers.python("socks5-server.py", [String(config.socksPort)]))
        XCTAssertTrue(TestServers.waitForPort(config.socksPort))

        let second = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = second
        second.socksBasePort = first.socksBasePort
        second.start()
        second.connect(config.id)
        XCTAssertTrue(wait { second.state(of: config.id) == .connected })
        let moved = second.configs.first { $0.id == config.id }!
        XCTAssertNotEqual(moved.socksPort, config.socksPort, "must not sit on the squatter's port")
    }

    /// A tunnel's HTTP port taken by the time it relaunches is reported with
    /// its owner and can be moved -- but is never moved silently, since
    /// exports and the system proxy refer to it.
    func testHTTPPortCollisionIsReportedAndMovable() {
        let first = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        first.httpBasePort = TestServers.freePort(); first.socksBasePort = TestServers.freePort()
        let config = first.add(target: "good-host")
        first.connect(config.id)
        XCTAssertTrue(wait { first.proxyServer(for: config.id) != nil })
        first.stopAll()
        XCTAssertTrue(wait(3) { !TestServers.waitForPort(config.httpPort, seconds: 0.2) })

        procs.append(TestServers.python("socks5-server.py", [String(config.httpPort)]))   // squatter
        XCTAssertTrue(TestServers.waitForPort(config.httpPort))

        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.socksBasePort = first.socksBasePort
        m.start()
        XCTAssertTrue(wait { m.bridgeError(for: config.id) != nil }, "a taken port must be reported")
        XCTAssertNil(m.proxyServer(for: config.id))
        XCTAssertEqual(m.configs.first?.httpPort, config.httpPort, "must not move on its own")
        XCTAssertTrue(m.bridgePortOwner(for: config.id)?.lowercased().contains("python") == true)

        let moved = m.moveBridgeToFreePort(config.id)
        XCTAssertNotNil(moved); XCTAssertNotEqual(moved, config.httpPort)
        XCTAssertTrue(wait { m.proxyServer(for: config.id)?.port == Int(moved!) }, "bridge should listen on the new port")
    }

    /// Configs saved before per-tunnel HTTP ports existed get one on load.
    func testOldConfigsWithoutHTTPPortAreMigrated() {
        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","target":"good-host","socksPort":\(TestServers.freePort()),"enabled":false}]
        """
        defaults.set(Data(legacy.utf8), forKey: "sshTunnels")
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.httpBasePort = TestServers.freePort()
        m.start()
        XCTAssertEqual(m.configs.count, 1)
        XCTAssertEqual(m.configs.first?.httpPort, m.httpBasePort)
    }

    func testGiveUpIsPerTunnel() {
        let m = TunnelManager(defaults: defaults, sshPath: fakeSSH)
        manager = m
        m.httpBasePort = TestServers.freePort()
        m.socksBasePort = TestServers.freePort()
        let bad = m.add(target: "fail-host")
        m.connect(bad.id)
        XCTAssertFalse(m.hasGivenUp(bad.id), "still retrying")
        // Real retry pacing is 8 s x 3; waiting that out here proves the
        // real cadence rather than a shortened one.
        XCTAssertTrue(wait(40) { m.hasGivenUp(bad.id) }, "\(m.state(of: bad.id))")
        // Another tunnel's fate is its own.
        let good = m.add(target: "good-host")
        m.connect(good.id)
        XCTAssertTrue(wait { m.state(of: good.id) == .connected })
        XCTAssertTrue(m.hasGivenUp(bad.id)); XCTAssertFalse(m.hasGivenUp(good.id))
    }
}
