import XCTest
@testable import SiphonCore

final class ShellExportsTests: XCTestCase {
    private let server = ProxyServer(host: "proxy.example.com", port: 3128)

    func testEmitsBothProtocols() {
        XCTAssertEqual(ShellExports.commands(for: server), """
        export HTTP_PROXY=http://proxy.example.com:3128
        export HTTPS_PROXY=http://proxy.example.com:3128
        """)
    }

    /// A proxy is reached over http even when it proxies https traffic.
    func testProxyURLIsAlwaysHTTP() {
        XCTAssertFalse(ShellExports.commands(for: server).contains("https://proxy"))
    }

    func testCarriesANonDefaultPort() {
        let alt = ProxyServer(host: "proxy.example.com", port: 8080)
        XCTAssertTrue(ShellExports.commands(for: alt).contains(":8080"))
    }

    /// The block is pasted into a shell, so it has to parse there.
    func testTheEmittedBlockRunsInARealShell() throws {
        let script = ShellExports.commands(for: server)
            + "\nprintf '%s|%s' \"$HTTP_PROXY\" \"$HTTPS_PROXY\""
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
                       "http://proxy.example.com:3128|http://proxy.example.com:3128")
    }
}
