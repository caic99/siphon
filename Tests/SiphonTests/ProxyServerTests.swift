import XCTest
@testable import SiphonCore

final class ProxyServerTests: XCTestCase {
    func testParsesHostAndPort() {
        XCTAssertEqual(ProxyServer.parse("proxy.example.com:8080"),
                       ProxyServer(host: "proxy.example.com", port: 8080))
    }

    func testDefaultsThePortWhenOmitted() {
        XCTAssertEqual(ProxyServer.parse("proxy.example.com"),
                       ProxyServer(host: "proxy.example.com", port: ProxyServer.defaultPort))
    }

    func testAcceptsIPv4Literals() {
        XCTAssertEqual(ProxyServer.parse("10.0.0.1:3128"),
                       ProxyServer(host: "10.0.0.1", port: 3128))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(ProxyServer.parse("  proxy.example.com:3128  "),
                       ProxyServer(host: "proxy.example.com", port: 3128))
    }

    func testRejectsUnusableInput() {
        // Each of these would end up as a command argument or a dictionary
        // value, so none of them may pass.
        for input in ["", "   ", ":3128", "proxy.example.com:", "proxy.example.com:abc",
                      "proxy.example.com:0", "proxy.example.com:65536",
                      "proxy.example.com:-1", "-lead.example.com", "trail-.example.com",
                      "has space.example.com", "proxy..example.com", "prox\\y.example.com",
                      "proxy;rm -rf /", "prox\"y.example.com"] {
            XCTAssertNil(ProxyServer.parse(input), "should reject \(input.debugDescription)")
        }
    }

    func testRejectsOverlongHostsAndLabels() {
        XCTAssertNil(ProxyServer.parse(String(repeating: "a", count: 64) + ".example.com"))
        let longHost = Array(repeating: "abcdefghij", count: 26).joined(separator: ".")
        XCTAssertGreaterThan(longHost.count, 253)
        XCTAssertNil(ProxyServer.parse(longHost))
    }

    func testDisplayRoundTrips() {
        let server = ProxyServer(host: "proxy.example.com", port: 3128)
        XCTAssertEqual(ProxyServer.parse(server.display), server)
    }
}
