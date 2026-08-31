import XCTest
@testable import SiphonCore

final class ShellExportsTests: XCTestCase {
    private let server = ProxyServer(host: "proxy.example.com", port: 3128)

    func testEmitsBothCasingsFromOneURL() {
        let out = ShellExports.commands(for: server, exceptions: [])
        XCTAssertEqual(out, """
        export http_proxy=http://proxy.example.com:3128
        export https_proxy=http://proxy.example.com:3128
        export no_proxy=localhost,127.0.0.1
        export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
        """)
    }

    /// macOS spells a domain wildcard "*.example.com"; no_proxy spells the same
    /// thing as a leading dot.
    func testTranslatesWildcardsToLeadingDots() {
        XCTAssertEqual(ShellExports.noProxy(exceptions: ["*.local", "*.example.com"]),
                       "localhost,127.0.0.1,.local,.example.com")
    }

    func testPassesThroughPlainHostsAndRanges() {
        XCTAssertEqual(ShellExports.noProxy(exceptions: ["169.254/16", "internal.example.com"]),
                       "localhost,127.0.0.1,169.254/16,internal.example.com")
    }

    /// Loopback leads even when unlisted: macOS bypasses it regardless, shells
    /// honour only what the variable says.
    func testAlwaysBypassesLoopback() {
        XCTAssertTrue(ShellExports.noProxy(exceptions: []).hasPrefix("localhost,127.0.0.1"))
    }

    func testDoesNotRepeatLoopbackWhenAlreadyListed() {
        XCTAssertEqual(ShellExports.noProxy(exceptions: ["localhost", "127.0.0.1", "*.local"]),
                       "localhost,127.0.0.1,.local")
    }

    /// A real exception list on this kind of Mac carries stray whitespace.
    func testTrimsAndSkipsEmptyEntries() {
        XCTAssertEqual(ShellExports.noProxy(exceptions: [" 192.168.0.0/16", "   ", "*.local"]),
                       "localhost,127.0.0.1,192.168.0.0/16,.local")
    }

    func testSetsEveryVariableToolsActuallyRead() {
        let exported = ShellExports.commands(for: server, exceptions: [])
        for name in ["http_proxy", "https_proxy", "no_proxy",
                     "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY"] {
            XCTAssertTrue(exported.contains(name), name)
        }
    }

    /// The block is pasted into a shell, so it must actually parse there.
    func testTheEmittedBlockRunsInARealShell() throws {
        let script = ShellExports.commands(for: server, exceptions: ["*.local", "169.254/16"])
            + "\nprintf '%s|%s' \"$http_proxy\" \"$NO_PROXY\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: data, as: UTF8.self),
                       "http://proxy.example.com:3128|localhost,127.0.0.1,.local,169.254/16")
    }
}
