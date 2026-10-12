import XCTest
@testable import SiphonCore

final class HTTPProxyRequestTests: XCTestCase {
    private func parse(_ s: String) throws -> HTTPProxyRequest {
        try HTTPProxyRequest.parse(Data(s.utf8))
    }

    func testConnectWithExplicitPort() throws {
        let r = try parse("CONNECT example.com:8443 HTTP/1.1\r\nHost: example.com:8443\r\n\r\n")
        XCTAssertEqual(r.kind, .connect(host: "example.com", port: 8443))
    }

    func testConnectDefaultsTo443() throws {
        XCTAssertEqual(try parse("CONNECT example.com HTTP/1.1\r\n\r\n").kind,
                       .connect(host: "example.com", port: 443))
    }

    func testConnectIPv6Literal() throws {
        XCTAssertEqual(try parse("CONNECT [2001:db8::1]:443 HTTP/1.1\r\n\r\n").kind,
                       .connect(host: "2001:db8::1", port: 443))
    }

    func testPlainRequestIsRewrittenToOriginForm() throws {
        let r = try parse("GET http://example.com/a/b?x=1 HTTP/1.1\r\nHost: example.com\r\n"
                          + "Proxy-Connection: keep-alive\r\nProxy-Authorization: Basic xx\r\n"
                          + "Connection: keep-alive\r\nAccept: */*\r\n\r\n")
        guard case .plain(let host, let port, let head) = r.kind else { return XCTFail("\(r)") }
        XCTAssertEqual(host, "example.com"); XCTAssertEqual(port, 80)
        XCTAssertEqual(String(decoding: head, as: UTF8.self),
                       "GET /a/b?x=1 HTTP/1.1\r\nHost: example.com\r\nAccept: */*\r\nConnection: close\r\n\r\n")
    }

    func testPlainRequestAddsHostWhenMissingAndKeepsNonDefaultPort() throws {
        let r = try parse("GET http://example.com:8080 HTTP/1.1\r\n\r\n")
        guard case .plain(let host, let port, let head) = r.kind else { return XCTFail("\(r)") }
        XCTAssertEqual(host, "example.com"); XCTAssertEqual(port, 8080)
        XCTAssertEqual(String(decoding: head, as: UTF8.self),
                       "GET / HTTP/1.1\r\nHost: example.com:8080\r\nConnection: close\r\n\r\n")
    }

    func testRejectsHTTPSAbsoluteURIAndRelativeTargets() {
        // https can only come through CONNECT; a relative path means the
        // client thinks we're the origin, not a proxy.
        XCTAssertThrowsError(try parse("GET https://example.com/ HTTP/1.1\r\n\r\n"))
        XCTAssertThrowsError(try parse("GET /index.html HTTP/1.1\r\n\r\n"))
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try parse("hello\r\n\r\n"))
        XCTAssertThrowsError(try parse("CONNECT :443 HTTP/1.1\r\n\r\n"))
        XCTAssertThrowsError(try parse("CONNECT example.com:notaport HTTP/1.1\r\n\r\n"))
    }

    func testHeadEndFindsTheBlankLine() {
        let d = Data("GET http://x/ HTTP/1.1\r\nA: b\r\n\r\nBODY".utf8)
        XCTAssertEqual(HTTPProxyRequest.headEnd(in: d), d.count - 4)
        XCTAssertNil(HTTPProxyRequest.headEnd(in: Data("GET http://x/ HTTP/1.1\r\nA: b\r\n".utf8)))
    }

    func testOversizedHeadIsRefused() {
        let big = "GET http://x/ HTTP/1.1\r\nX: " + String(repeating: "a", count: 70_000) + "\r\n\r\n"
        XCTAssertThrowsError(try parse(big)) { XCTAssertEqual($0 as? HTTPProxyRequest.ParseError, .headTooLarge) }
    }
}
