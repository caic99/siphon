import XCTest
@testable import SiphonCore

final class SOCKS5Tests: XCTestCase {
    func testGreetingOffersNoAuthOnly() {
        XCTAssertEqual(Array(SOCKS5.greeting), [0x05, 0x01, 0x00])
    }

    func testGreetingReply() {
        XCTAssertNoThrow(try SOCKS5.checkGreetingReply(Data([0x05, 0x00])))
        XCTAssertThrowsError(try SOCKS5.checkGreetingReply(Data([0x05, 0xff]))) {
            XCTAssertEqual($0 as? SOCKS5.Error, .noAcceptableAuth)
        }
        XCTAssertThrowsError(try SOCKS5.checkGreetingReply(Data([0x04, 0x00])))
        XCTAssertThrowsError(try SOCKS5.checkGreetingReply(Data([0x05])))
    }

    func testConnectRequestUsesDomainNameAddressType() throws {
        let req = try SOCKS5.connectRequest(host: "example.com", port: 443)
        XCTAssertEqual(Array(req.prefix(5)), [0x05, 0x01, 0x00, 0x03, 11])
        XCTAssertEqual(String(decoding: req[5..<16], as: UTF8.self), "example.com")
        XCTAssertEqual(Array(req.suffix(2)), [0x01, 0xbb])   // 443
    }

    func testConnectRequestRejectsOverlongHostname() {
        XCTAssertThrowsError(try SOCKS5.connectRequest(host: String(repeating: "a", count: 256), port: 80))
    }

    func testReplyParsingHandlesEachAddressTypeAndPartialReads() throws {
        XCTAssertEqual(try SOCKS5.parseConnectReply(Data([0x05, 0x00])), .needMore(4))
        // IPv4: 4 + 4 + 2
        XCTAssertEqual(try SOCKS5.parseConnectReply(Data([0x05,0x00,0x00,0x01, 0,0,0,0])), .needMore(10))
        XCTAssertEqual(try SOCKS5.parseConnectReply(Data([0x05,0x00,0x00,0x01, 0,0,0,0, 0,0, 0xAA])),
                       .connected(consumed: 10))
        // Domain: 4 + 1 + len + 2
        XCTAssertEqual(try SOCKS5.parseConnectReply(Data([0x05,0x00,0x00,0x03])), .needMore(5))
        XCTAssertEqual(try SOCKS5.parseConnectReply(Data([0x05,0x00,0x00,0x03, 3, 0x61,0x62,0x63, 0,80])),
                       .connected(consumed: 10))
        // IPv6: 4 + 16 + 2
        XCTAssertEqual(try SOCKS5.parseConnectReply(Data([0x05,0x00,0x00,0x04] + [UInt8](repeating: 0, count: 18))),
                       .connected(consumed: 22))
    }

    func testReplyRefusalSurfacesTheCode() {
        XCTAssertThrowsError(try SOCKS5.parseConnectReply(Data([0x05, 0x05, 0x00, 0x01, 0,0,0,0, 0,0]))) {
            XCTAssertEqual($0 as? SOCKS5.Error, .refused(code: 0x05))
        }
        XCTAssertEqual(SOCKS5.describe(0x05), "connection refused")
    }
}
