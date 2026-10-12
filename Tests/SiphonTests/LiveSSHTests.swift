import XCTest
@testable import SiphonCore

/// One real `ssh -N -D` to the host named in SIPHON_LIVE_SSH, a request through
/// the bridge, then teardown. Uses the real ssh binary, the user's own config
/// and agent, and runs no remote command. Opt-in:
///
///     SIPHON_LIVE_SSH=some-host swift test --filter LiveSSHTests
final class LiveSSHTests: XCTestCase {
    func testTunnelToRealHostCarriesTraffic() throws {
        guard let host = ProcessInfo.processInfo.environment["SIPHON_LIVE_SSH"], !host.isEmpty else {
            throw XCTSkip("set SIPHON_LIVE_SSH=<host> to run")
        }
        let suite = "siphon.live.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let m = TunnelManager(defaults: defaults)
        defer { m.stopAll() }
        m.httpPort = TestServers.freePort()      // tunnelmux may hold 7890
        let config = m.add(target: host)

        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, m.state(of: config.id) != .connected {
            if case .gaveUp = m.state(of: config.id) { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTAssertEqual(m.state(of: config.id), .connected, "tunnel state: \(m.state(of: config.id))")
        XCTAssertNotNil(m.proxyServer, "bridge error: \(m.bridgeError ?? "-")")

        // Any HTTP status proves bytes went host -> tunnel -> origin and back.
        let (status, code) = TestServers.curl(["-o", "/dev/null", "-w", "%{http_code}",
                                               "-x", "http://127.0.0.1:\(m.httpPort)",
                                               "https://www.nvidia.com/"])
        print("live: curl exit \(status), HTTP \(code) via \(host)")
        XCTAssertNotEqual(code, "000", "no HTTP response came back through the tunnel")
    }
}
