import XCTest
@testable import SiphonCore

/// The bridge against a real SOCKS5 server and a real origin, driven by curl —
/// the same client that will sit behind it in practice.
final class HTTPProxyBridgeTests: XCTestCase {
    private var procs: [Process] = []
    private var bridge: HTTPProxyBridge?

    override func tearDown() {
        bridge?.stop()
        for p in procs where p.isRunning { p.terminate() }
        procs.removeAll()
    }

    private func startWorld(upstream: @escaping () -> UInt16?) -> (bridge: UInt16, origin: UInt16) {
        let originPort = TestServers.freePort(), bridgePort = TestServers.freePort()
        procs.append(TestServers.originServer(port: originPort))
        XCTAssertTrue(TestServers.waitForPort(originPort), "origin did not start")
        let b = HTTPProxyBridge(port: bridgePort, upstream: upstream)
        bridge = b
        b.start()
        XCTAssertTrue(TestServers.waitForPort(bridgePort), "bridge did not listen")
        return (bridgePort, originPort)
    }

    private func startSOCKS() -> UInt16 {
        let port = TestServers.freePort()
        procs.append(TestServers.python("socks5-server.py", [String(port)]))
        XCTAssertTrue(TestServers.waitForPort(port), "socks server did not start")
        return port
    }

    func testPlainHTTPGoesThroughTheSOCKSServer() {
        let socks = startSOCKS()
        let w = startWorld(upstream: { socks })
        let (status, body) = TestServers.curl(["-x", "http://127.0.0.1:\(w.bridge)",
                                               "http://127.0.0.1:\(w.origin)/hello.txt"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(body, "hello through the tunnel\n")
    }

    /// `-p` makes curl use CONNECT even for http, exercising the HTTPS path
    /// without needing a TLS origin.
    func testConnectTunnelsRawBytes() {
        let socks = startSOCKS()
        let w = startWorld(upstream: { socks })
        let (status, body) = TestServers.curl(["-p", "-x", "http://127.0.0.1:\(w.bridge)",
                                               "http://127.0.0.1:\(w.origin)/hello.txt"])
        XCTAssertEqual(status, 0)
        XCTAssertEqual(body, "hello through the tunnel\n")
    }

    func testNoUpstreamYields503() {
        let w = startWorld(upstream: { nil })
        let (_, out) = TestServers.curl(["-o", "/dev/null", "-w", "%{http_code}",
                                         "-x", "http://127.0.0.1:\(w.bridge)",
                                         "http://127.0.0.1:\(w.origin)/hello.txt"])
        XCTAssertEqual(out, "503")
    }

    func testUnreachableOriginYields502() {
        let socks = startSOCKS()
        let w = startWorld(upstream: { socks })
        let dead = TestServers.freePort()
        let (_, out) = TestServers.curl(["-o", "/dev/null", "-w", "%{http_code}",
                                         "-x", "http://127.0.0.1:\(w.bridge)",
                                         "http://127.0.0.1:\(dead)/"])
        XCTAssertEqual(out, "502")
    }

    func testBindsLoopbackOnly() {
        let w = startWorld(upstream: { nil })
        // Any non-loopback address of this Mac must refuse the connection.
        let (status, _) = TestServers.curl(["-x", "http://0.0.0.0:\(w.bridge)", "http://example.invalid/"])
        _ = status
        let out = Process(); out.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        out.arguments = ["-nP", "-iTCP:\(w.bridge)", "-sTCP:LISTEN"]
        let pipe = Pipe(); out.standardOutput = pipe; try! out.run()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        out.waitUntilExit()
        XCTAssertTrue(text.contains("127.0.0.1:\(w.bridge)"), text)
        XCTAssertFalse(text.contains("*:\(w.bridge)"), "listening on all interfaces:\n\(text)")
    }
}
