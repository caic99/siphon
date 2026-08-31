import XCTest
@testable import SiphonCore

final class ProxyDictionaryTests: XCTestCase {
    /// A service's Proxies dictionary as macOS actually reports it: the six keys
    /// Siphon owns, and several it must not disturb.
    private func realistic() -> ProxyDictionary {
        ProxyDictionary(entries: [
            "HTTPEnable": .number(1),
            "HTTPProxy": .string("proxy.example.com"),
            "HTTPPort": .number(3128),
            "HTTPSEnable": .number(1),
            "HTTPSProxy": .string("proxy.example.com"),
            "HTTPSPort": .number(3128),
            "ExceptionsList": .array(["*.local", "169.254/16"]),
            "ExcludeSimpleHostnames": .number(1),
            "FTPPassive": .number(1),
        ])
    }

    // MARK: - Reading

    func testConvertsSystemDictionaryValues() {
        let dictionary = ProxyDictionary(systemDictionary: [
            "HTTPEnable": 1 as NSNumber,
            "HTTPProxy": "proxy.example.com",
            "ExceptionsList": ["*.local", "169.254/16"],
        ])
        XCTAssertEqual(dictionary.entries["HTTPEnable"], .number(1))
        XCTAssertEqual(dictionary.entries["HTTPProxy"], .string("proxy.example.com"))
        XCTAssertEqual(dictionary.entries["ExceptionsList"], .array(["*.local", "169.254/16"]))
        XCTAssertEqual(dictionary.droppedKeys, [])
    }

    func testTreatsBooleansAsNumbers() {
        let dictionary = ProxyDictionary(systemDictionary: ["FTPPassive": true])
        XCTAssertEqual(dictionary.entries["FTPPassive"], .number(1))
    }

    /// scutil has no escape for a literal backslash, and nested dictionaries
    /// cannot be expressed at all. Reporting beats silently mangling.
    func testDropsValuesScutilCannotExpress() {
        let dictionary = ProxyDictionary(systemDictionary: [
            "HTTPEnable": 1 as NSNumber,
            "Nested": ["a": "b"],
            "Backslash": #"C:\path"#,
            "MixedArray": ["ok", 5] as [Any],
        ])
        XCTAssertEqual(dictionary.droppedKeys, ["Backslash", "MixedArray", "Nested"])
        XCTAssertEqual(dictionary.entries.count, 1)
    }

    func testReadsEnabledStateAndServer() {
        XCTAssertTrue(realistic().isOn)
        XCTAssertEqual(realistic().server, ProxyServer(host: "proxy.example.com", port: 3128))

        XCTAssertFalse(realistic().disabled().isOn)
        // Host and port survive being turned off, matching networksetup.
        XCTAssertEqual(realistic().disabled().server,
                       ProxyServer(host: "proxy.example.com", port: 3128))
    }

    func testMissingKeysReadAsOff() {
        let empty = ProxyDictionary()
        XCTAssertFalse(empty.isOn)
        XCTAssertNil(empty.server)
    }

    // MARK: - Editing

    /// The bug this app exists to fix: the shell script rebuilt the dictionary
    /// from scratch and dropped every key it did not write.
    func testEditingPreservesUnrelatedKeys() {
        let updated = realistic().enabling(ProxyServer(host: "other.example.com", port: 8080))
        XCTAssertEqual(updated.entries["ExceptionsList"], .array(["*.local", "169.254/16"]))
        XCTAssertEqual(updated.entries["ExcludeSimpleHostnames"], .number(1))
        XCTAssertEqual(updated.entries["FTPPassive"], .number(1))

        let cleared = realistic().disabled()
        XCTAssertEqual(cleared.entries["ExceptionsList"], .array(["*.local", "169.254/16"]))
        XCTAssertEqual(cleared.entries["FTPPassive"], .number(1))
    }

    func testEnablingSetsBothProtocols() {
        let updated = ProxyDictionary().enabling(ProxyServer(host: "other.example.com", port: 8080))
        XCTAssertEqual(updated.entries["HTTPEnable"], .number(1))
        XCTAssertEqual(updated.entries["HTTPProxy"], .string("other.example.com"))
        XCTAssertEqual(updated.entries["HTTPPort"], .number(8080))
        XCTAssertEqual(updated.entries["HTTPSEnable"], .number(1))
        XCTAssertEqual(updated.entries["HTTPSProxy"], .string("other.example.com"))
        XCTAssertEqual(updated.entries["HTTPSPort"], .number(8080))
    }

    func testDisablingClearsBothProtocols() {
        let cleared = realistic().disabled()
        XCTAssertEqual(cleared.entries["HTTPEnable"], .number(0))
        XCTAssertEqual(cleared.entries["HTTPSEnable"], .number(0))
    }

    // MARK: - Encoding

    func testEncodesEachValueKind() {
        let dictionary = ProxyDictionary(entries: [
            "HTTPProxy": .string("proxy.example.com"),
            "HTTPPort": .number(3128),
            "ExceptionsList": .array(["*.local", "169.254/16"]),
        ])
        XCTAssertEqual(dictionary.scutilCommands(setting: "State:/Network/Service/ABC/Proxies"), [
            "d.init",
            #"d.add ExceptionsList * "*.local" "169.254/16""#,
            "d.add HTTPPort # 3128",
            #"d.add HTTPProxy "proxy.example.com""#,
            "set State:/Network/Service/ABC/Proxies",
        ])
    }

    func testEncodesEmptyArray() {
        let dictionary = ProxyDictionary(entries: ["ExceptionsList": .array([])])
        XCTAssertEqual(dictionary.scutilCommands(setting: "K")[1], "d.add ExceptionsList *")
    }

    func testQuotesValuesThatWouldOtherwiseSplit() {
        XCTAssertEqual(ProxyDictionary.quote("a b"), "\"a b\"")
        XCTAssertEqual(ProxyDictionary.quote(""), "\"\"")
        XCTAssertEqual(ProxyDictionary.quote("say \"hi\""), #""say \"hi\"""#)
    }
}
