import XCTest
@testable import SiphonCore

/// A quoting bug here would run the wrong command as root, so these are checked
/// against a real shell as well as against expected strings.
final class ShellQuotingTests: XCTestCase {
    func testQuotesOrdinaryArguments() {
        XCTAssertEqual(Shell.quote("Wi-Fi"), "'Wi-Fi'")
        XCTAssertEqual(Shell.quote(""), "''")
    }

    func testQuotesArgumentsContainingShellMetacharacters() {
        XCTAssertEqual(Shell.quote("USB 10/100/1000 LAN"), "'USB 10/100/1000 LAN'")
        XCTAssertEqual(Shell.quote("a; rm -rf /"), "'a; rm -rf /'")
        XCTAssertEqual(Shell.quote("$(whoami)"), "'$(whoami)'")
        XCTAssertEqual(Shell.quote("it's"), #"'it'\''s'"#)
    }

    /// The shell itself is the authority on whether the quoting is right.
    func testRealShellRecoversTheOriginalArgument() throws {
        for value in ["Wi-Fi", "USB 10/100/1000 LAN", "it's", "a; rm -rf /", "$(whoami)",
                      #"say "hi""#, "back\\slash", "*", ""] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", "printf %s \(Shell.quote(value))"]
            let output = Pipe()
            process.standardOutput = output
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            XCTAssertEqual(String(decoding: data, as: UTF8.self), value)
        }
    }

    func testAppleScriptLiteralEscapesBackslashesBeforeQuotes() {
        XCTAssertEqual(Shell.appleScriptLiteral("plain"), "\"plain\"")
        XCTAssertEqual(Shell.appleScriptLiteral(#"say "hi""#), #""say \"hi\"""#)
        XCTAssertEqual(Shell.appleScriptLiteral(#"back\slash"#), #""back\\slash""#)
    }

    func testCommandQuotesPathAndArguments() {
        let command = PrivilegedCommand(path: "/usr/sbin/networksetup",
                                        arguments: ["-setwebproxy", "USB 10/100/1000 LAN",
                                                    "proxy.example.com", "3128"])
        XCTAssertEqual(Shell.command(for: command),
                       "'/usr/sbin/networksetup' '-setwebproxy' 'USB 10/100/1000 LAN' "
                       + "'proxy.example.com' '3128'")
    }

    /// stdin is delivered as printf arguments, so no dictionary line can escape
    /// its quoting and terminate the command early.
    func testCommandPipesInputThroughPrintf() {
        let command = PrivilegedCommand(path: "/usr/sbin/scutil",
                                        input: "d.init\nd.add HTTPEnable # 1\nset K")
        XCTAssertEqual(Shell.command(for: command),
                       "'/usr/bin/printf' '%s\n' 'd.init' 'd.add HTTPEnable # 1' 'set K' "
                       + "| '/usr/sbin/scutil'")
    }

    func testAdminScriptJoinsCommandsSoItAsksOnce() {
        let script = Shell.adminScript(for: [
            PrivilegedCommand(path: "/bin/a"),
            PrivilegedCommand(path: "/bin/b"),
        ])
        XCTAssertEqual(script, #"do shell script "'/bin/a' && '/bin/b'" with administrator privileges"#)
    }

    func testAdminScriptIsAWellFormedAppleScriptString() throws {
        // A service name with a quote in it must not break out of the literal.
        let command = PrivilegedCommand(path: "/bin/echo", arguments: [#"a "b" c"#])
        let script = Shell.adminScript(for: [command])
        XCTAssertTrue(script.hasPrefix("do shell script \""))
        XCTAssertTrue(script.hasSuffix("\" with administrator privileges"))
        let body = script.dropFirst("do shell script ".count)
            .dropLast(" with administrator privileges".count)
        // Every unescaped quote in the literal must be one of the two delimiters.
        let unescaped = body.replacingOccurrences(of: "\\\\", with: "")
            .replacingOccurrences(of: "\\\"", with: "")
        XCTAssertEqual(unescaped.filter { $0 == "\"" }.count, 2, String(body))
    }
}
