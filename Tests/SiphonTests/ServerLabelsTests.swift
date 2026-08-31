import XCTest
@testable import SiphonCore

final class ServerLabelsTests: XCTestCase {
    private func server(_ host: String, _ port: Int = 3128) -> ProxyServer {
        ProxyServer(host: host, port: port)
    }

    func testDropsTheDomainWhenShortFormsStayUnique() {
        XCTAssertEqual(ServerLabels.labels(for: [server("proxy17.example.com"),
                                                 server("proxy15.example.com")]),
                       ["proxy17:3128", "proxy15:3128"])
    }

    /// Two hosts sharing a first label in different domains must not collapse
    /// into the same row.
    func testKeepsFullNamesWhenShorteningWouldCollide() {
        let servers = [server("proxy.a.example.com"), server("proxy.b.example.com")]
        XCTAssertEqual(ServerLabels.labels(for: servers), servers.map(\.display))
    }

    /// Same first label but different ports still disambiguates, so shortening
    /// is safe.
    func testPortsCanBeWhatMakesShortFormsUnique() {
        XCTAssertEqual(ServerLabels.labels(for: [server("proxy.a.example.com", 3128),
                                                 server("proxy.b.example.com", 8080)]),
                       ["proxy:3128", "proxy:8080"])
    }

    func testLeavesIPLiteralsAlone() {
        XCTAssertEqual(ServerLabels.labels(for: [server("127.0.0.1", 7890)]), ["127.0.0.1:7890"])
    }

    func testMixesShortenedNamesAndIPs() {
        XCTAssertEqual(ServerLabels.labels(for: [server("proxy17.example.com"),
                                                 server("127.0.0.1", 7890)]),
                       ["proxy17:3128", "127.0.0.1:7890"])
    }

    func testLeavesBareHostnamesAlone() {
        XCTAssertEqual(ServerLabels.labels(for: [server("localhost", 8080)]), ["localhost:8080"])
    }

    func testEmptyList() {
        XCTAssertEqual(ServerLabels.labels(for: []), [])
    }
}
