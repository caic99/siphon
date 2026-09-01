import XCTest
@testable import SiphonCore

/// Exercises the privileged `scutil` path end to end — the branch tunnel
/// interfaces take, which cannot be reached from unit tests and only runs live
/// when a tunnel owns the default route.
///
/// Writes to a dynamic-store key for a service ID that does not exist, so
/// nothing on the machine is affected, and removes it afterwards. Needs
/// passwordless sudo, so it is opt-in:
///
///     SIPHON_ROOT_TESTS=1 swift test
final class TunnelWriteIntegrationTests: XCTestCase {
    private let target = ProxyTarget(serviceID: "SIPHON-TEST-0000-0000-000000000000",
                                     name: "Siphon Test", isTunnel: true)
    private let runner = PrivilegeRunner()

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIPHON_ROOT_TESTS"] == "1",
                          "set SIPHON_ROOT_TESTS=1 to run privileged tests")
        try XCTSkipUnless(runner.canRunSilently([ProxyPolicy.scutil]),
                          "needs passwordless sudo for scutil")
    }

    override func tearDown() {
        _ = runner.run([PrivilegedCommand(path: ProxyPolicy.scutil,
                                          input: "remove \(target.proxyKey)")],
                       allowPrompt: false)
    }

    private func write(_ intent: ProxyIntent, existing: ProxyDictionary) -> ProxyDictionary {
        let commands = ProxyPolicy.commands(for: intent, on: target, existing: existing)
        XCTAssertEqual(runner.run(commands, allowPrompt: false), .success)
        return NetworkState.proxies(forKey: target.proxyKey)
    }

    /// What a tunnel arrives with before Siphon touches anything: proxy off, but carrying
    /// exceptions the shell script's `d.init` + `set` would have destroyed.
    private func seed() -> ProxyDictionary {
        ProxyDictionary(entries: [
            "ExceptionsList": .array(["*.local", "169.254/16", "two words"]),
            "ExcludeSimpleHostnames": .number(1),
            "FTPPassive": .number(1),
        ])
    }

    func testEnableThenDisablePreservesEverythingElse() {
        let server = ProxyServer(host: "proxy.example.com", port: 3128)

        let enabled = write(.enable(server), existing: seed())
        XCTAssertTrue(enabled.isOn)
        XCTAssertEqual(enabled.server, server)
        XCTAssertEqual(enabled.entries["HTTPSProxy"], .string("proxy.example.com"))
        XCTAssertEqual(enabled.entries["HTTPSPort"], .number(3128))
        // The whole point: the dictionary survived a full rewrite.
        XCTAssertEqual(enabled.entries["ExceptionsList"],
                       .array(["*.local", "169.254/16", "two words"]))
        XCTAssertEqual(enabled.entries["ExcludeSimpleHostnames"], .number(1))
        XCTAssertEqual(enabled.entries["FTPPassive"], .number(1))
        XCTAssertEqual(enabled.droppedKeys, [])

        let disabled = write(.disable, existing: enabled)
        XCTAssertFalse(disabled.isOn)
        XCTAssertEqual(disabled.entries["HTTPSEnable"], .number(0))
        // Host and port stay, matching networksetup's off behaviour.
        XCTAssertEqual(disabled.server, server)
        XCTAssertEqual(disabled.entries["ExceptionsList"],
                       .array(["*.local", "169.254/16", "two words"]))
    }

    func testWritingToAnEmptyKeyCreatesAUsableDictionary() {
        let server = ProxyServer(host: "proxy.example.com", port: 8080)
        let written = write(.enable(server), existing: ProxyDictionary())
        XCTAssertTrue(written.isOn)
        XCTAssertEqual(written.server, server)
        XCTAssertEqual(written.entries.count, 6)
    }
}
