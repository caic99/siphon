import XCTest
@testable import SiphonCore

final class ServerReachabilityTests: XCTestCase {
    private let a = ProxyServer(host: "a.example.com", port: 3128)
    private let b = ProxyServer(host: "b.example.com", port: 3128)

    /// A fake prober that records what it was asked and answers on demand.
    private final class Recorder {
        var asked: [ProxyServer] = []
        var pending: [(ProxyServer, (ServerReachability.Status) -> Void)] = []
        lazy var prober: ServerReachability.Prober = { [unowned self] server, _, done in
            self.asked.append(server)
            self.pending.append((server, done))
        }
        func answerAll(_ status: ServerReachability.Status) {
            let batch = pending; pending = []
            for (_, done) in batch { done(status) }
        }
    }

    private func settle() {
        let e = expectation(description: "main queue drained")
        DispatchQueue.main.async { e.fulfill() }
        wait(for: [e], timeout: 1)
    }

    func testUnprobedServersAreUnknownThenCheckingThenAnswered() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        XCTAssertEqual(r.status(of: a), .unknown)
        r.check([a])
        XCTAssertEqual(r.status(of: a), .checking)
        rec.answerAll(.reachable(latency: 0.01))
        settle()
        XCTAssertEqual(r.status(of: a), .reachable(latency: 0.01))
    }

    func testDoesNotReprobeWithinTheMinimumInterval() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        r.minimumInterval = 60
        r.check([a, b]); rec.answerAll(.unreachable("connection refused")); settle()
        r.check([a, b])
        XCTAssertEqual(rec.asked.count, 2, "a second check inside the interval must not probe again")
        r.check([a, b], force: true)
        XCTAssertEqual(rec.asked.count, 4, "force bypasses the interval")
    }

    /// A probe in flight must not be duplicated by an impatient second check.
    func testDoesNotStackProbesWhileOneIsOut() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        r.check([a]); r.check([a], force: true)
        XCTAssertEqual(rec.asked, [a])
    }

    func testKeepsTheLastAnswerWhileReprobing() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        r.check([a]); rec.answerAll(.reachable(latency: 0.02)); settle()
        r.check([a], force: true)
        XCTAssertEqual(r.status(of: a), .reachable(latency: 0.02), "no grey flicker on re-check")
    }

    func testForgetsServersThatLeftTheList() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        r.check([a, b]); rec.answerAll(.reachable(latency: 0.01)); settle()
        r.check([a])
        XCTAssertEqual(r.status(of: b), .unknown)
    }

    func testFiresOnChangeOnlyWhenAStatusActuallyChanges() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        var fired = 0
        r.onChange = { fired += 1 }
        r.check([a])                                   // unknown -> checking
        rec.answerAll(.unreachable("timed out")); settle()  // checking -> unreachable
        r.check([a], force: true)
        rec.answerAll(.unreachable("timed out")); settle()  // same answer: no fire
        XCTAssertEqual(fired, 2)
    }

    func testSeedIsFinalAndNotReprobed() {
        let rec = Recorder()
        let r = ServerReachability(prober: rec.prober)
        r.seed(a, .reachable(latency: 0.005))
        r.check([a])
        XCTAssertTrue(rec.asked.isEmpty)
        XCTAssertEqual(r.status(of: a), .reachable(latency: 0.005))
    }

    // MARK: - The real TCP probe

    func testTCPProbeReachesALocalListener() {
        let port = TestServers.freePort()
        let origin = TestServers.originServer(port: port)
        defer { origin.terminate() }
        XCTAssertTrue(TestServers.waitForPort(port), "origin did not start")
        let e = expectation(description: "probe")
        var got: ServerReachability.Status = .unknown
        ServerReachability.tcpProbe(ProxyServer(host: "127.0.0.1", port: Int(port)), timeout: 3) { got = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        guard case .reachable(let latency) = got else { return XCTFail("expected reachable, got \(got)") }
        XCTAssertLessThan(latency, 3)
    }

    func testTCPProbeReportsAClosedPortAsRefused() {
        let port = TestServers.freePort()
        let e = expectation(description: "probe")
        var got: ServerReachability.Status = .unknown
        ServerReachability.tcpProbe(ProxyServer(host: "127.0.0.1", port: Int(port)), timeout: 3) { got = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        XCTAssertEqual(got, .unreachable("connection refused"))
    }

    func testTCPProbeTimesOutOnABlackHole() {
        // 192.0.2.0/24 is TEST-NET-1: reserved for documentation, never routed.
        let e = expectation(description: "probe")
        var got: ServerReachability.Status = .unknown
        ServerReachability.tcpProbe(ProxyServer(host: "192.0.2.1", port: 3128), timeout: 1) { got = $0; e.fulfill() }
        wait(for: [e], timeout: 5)
        guard case .unreachable = got else { return XCTFail("expected unreachable, got \(got)") }
    }
}
