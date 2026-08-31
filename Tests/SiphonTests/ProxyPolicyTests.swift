import XCTest
@testable import SiphonCore

final class ProxyPolicyTests: XCTestCase {
    private let ours = ProxyServer(host: "proxy.example.com", port: 3128)
    private let theirs = ProxyServer(host: "other.example.com", port: 8080)

    private func dictionary(on: Bool, server: ProxyServer?) -> ProxyDictionary {
        var entries: [String: SCValue] = ["HTTPEnable": .number(on ? 1 : 0)]
        if let server {
            entries["HTTPProxy"] = .string(server.host)
            entries["HTTPPort"] = .number(server.port)
        }
        return ProxyDictionary(entries: entries)
    }

    private func plan(desiredOn: Bool,
                      server: ProxyServer? = nil,
                      current: ProxyDictionary?,
                      serviceIsOurs: Bool = false,
                      canRunSilently: Bool = true,
                      trigger: ProxyTrigger = .automatic) -> ProxyPlan {
        ProxyPolicy.plan(desiredOn: desiredOn, server: server ?? ours, current: current,
                         serviceIsOurs: serviceIsOurs, canRunSilently: canRunSilently,
                         trigger: trigger)
    }

    // MARK: - Nothing to act on

    func testNoPrimaryServiceIsUnavailable() {
        XCTAssertEqual(plan(desiredOn: true, current: nil), .unavailable)
    }

    func testNoServerChosenIsUnavailable() {
        let plan = ProxyPolicy.plan(desiredOn: true, server: nil,
                                    current: dictionary(on: false, server: nil),
                                    serviceIsOurs: false, canRunSilently: true,
                                    trigger: .userClick)
        XCTAssertEqual(plan, .unavailable)
    }

    func testAlreadyMatchingIsSatisfied() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: true, server: ours)),
                       .satisfied)
        XCTAssertEqual(plan(desiredOn: false, current: dictionary(on: false, server: ours)),
                       .satisfied)
    }

    // MARK: - Turning on

    func testTurningOnWritesWhenSudoIsSilent() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: false, server: nil)),
                       .write(.enable(ours)))
    }

    /// A password dialog must never appear without the user having clicked.
    func testAutomaticApplyWaitsWhenSudoWouldPrompt() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: false, server: nil),
                            canRunSilently: false),
                       .awaitingUser(.enable(ours)))
    }

    func testAClickMayPromptForAPassword() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: false, server: nil),
                            canRunSilently: false, trigger: .userClick),
                       .write(.enable(ours)))
    }

    func testChangingServerRewritesOurOwnService() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: true, server: theirs),
                            serviceIsOurs: true),
                       .write(.enable(ours)))
    }

    // MARK: - Someone else's proxy

    func testAutomaticApplyRefusesToOverwriteAProxyWeDidNotSet() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: true, server: theirs)),
                       .foreignProxy(theirs))
    }

    func testAClickOverwritesAProxyWeDidNotSet() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: true, server: theirs),
                            trigger: .userClick),
                       .write(.enable(ours)))
    }

    func testForeignProxyWithNoRecordedHostStillReports() {
        XCTAssertEqual(plan(desiredOn: true, current: dictionary(on: true, server: nil)),
                       .foreignProxy(nil))
    }

    // MARK: - Turning off

    func testTurningOffClearsAServiceWeProxied() {
        XCTAssertEqual(plan(desiredOn: false, current: dictionary(on: true, server: ours),
                            serviceIsOurs: true),
                       .write(.disable))
    }

    /// Siphon does not switch off a proxy it never switched on — unless asked.
    func testTurningOffLeavesAProxyWeDidNotSet() {
        XCTAssertEqual(plan(desiredOn: false, current: dictionary(on: true, server: theirs)),
                       .satisfied)
    }

    func testAClickTurnsOffEvenAProxyWeDidNotSet() {
        XCTAssertEqual(plan(desiredOn: false, current: dictionary(on: true, server: theirs),
                            trigger: .userClick),
                       .write(.disable))
    }

    func testAutomaticClearWaitsWhenSudoWouldPrompt() {
        XCTAssertEqual(plan(desiredOn: false, current: dictionary(on: true, server: ours),
                            serviceIsOurs: true, canRunSilently: false),
                       .awaitingUser(.disable))
    }

    // MARK: - Commands

    func testTunnelCommandsRewriteTheWholeDictionary() {
        let target = ProxyTarget(serviceID: "ABC", name: "VPN", isTunnel: true)
        let existing = ProxyDictionary(entries: ["ExceptionsList": .array(["*.local"])])
        let commands = ProxyPolicy.commands(for: .enable(ours), on: target, existing: existing)

        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].path, "/usr/sbin/scutil")
        XCTAssertEqual(commands[0].arguments, [])
        let script = try! XCTUnwrap(commands[0].input)
        XCTAssertTrue(script.contains(#"d.add ExceptionsList * "*.local""#), script)
        XCTAssertTrue(script.contains("d.add HTTPEnable # 1"), script)
        XCTAssertTrue(script.contains(#"d.add HTTPProxy "proxy.example.com""#), script)
        XCTAssertTrue(script.hasSuffix("set State:/Network/Service/ABC/Proxies"), script)
    }

    func testTunnelDisableKeepsTheServerAndExceptions() {
        let target = ProxyTarget(serviceID: "ABC", name: "VPN", isTunnel: true)
        let existing = ProxyDictionary(entries: [
            "HTTPEnable": .number(1),
            "HTTPProxy": .string("proxy.example.com"),
            "ExceptionsList": .array(["*.local"]),
        ])
        let script = try! XCTUnwrap(
            ProxyPolicy.commands(for: .disable, on: target, existing: existing).first?.input)
        XCTAssertTrue(script.contains("d.add HTTPEnable # 0"), script)
        XCTAssertTrue(script.contains(#"d.add HTTPProxy "proxy.example.com""#), script)
        XCTAssertTrue(script.contains(#"d.add ExceptionsList * "*.local""#), script)
    }

    /// networksetup touches only the web-proxy keys, so no rewrite is needed —
    /// but both protocols must be set, and by service name.
    func testPhysicalServiceCommandsUseNetworksetup() {
        let target = ProxyTarget(serviceID: "DEF", name: "USB 10/100/1000 LAN", isTunnel: false)
        let enable = ProxyPolicy.commands(for: .enable(ours), on: target, existing: ProxyDictionary())
        XCTAssertEqual(enable.map(\.arguments), [
            ["-setwebproxy", "USB 10/100/1000 LAN", "proxy.example.com", "3128"],
            ["-setsecurewebproxy", "USB 10/100/1000 LAN", "proxy.example.com", "3128"],
        ])
        XCTAssertTrue(enable.allSatisfy { $0.path == "/usr/sbin/networksetup" && $0.input == nil })

        let disable = ProxyPolicy.commands(for: .disable, on: target, existing: ProxyDictionary())
        XCTAssertEqual(disable.map(\.arguments), [
            ["-setwebproxystate", "USB 10/100/1000 LAN", "off"],
            ["-setsecurewebproxystate", "USB 10/100/1000 LAN", "off"],
        ])
    }
}
