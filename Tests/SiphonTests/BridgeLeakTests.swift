import XCTest
@testable import SiphonCore

/// Connections through the bridge must be released once the client is gone.
/// Measured on the real app: hundreds of relays whose client had vanished
/// stayed open indefinitely.
final class BridgeLeakTests: XCTestCase {
    private var procs: [Process] = []
    private var bridge: HTTPProxyBridge?
    override func tearDown() { bridge?.stop(); procs.forEach { if $0.isRunning { $0.terminate() } } }

    private func openSockets(toPort port: UInt16) -> Int {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try! p.run(); let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); p.waitUntilExit()
        // Lines where our process holds the *server* side of a relayed connection.
        return text.split(separator: "\n").filter { $0.contains("127.0.0.1:\(port)->") }.count
    }

    func testRelaysAreReleasedAfterClientsDisconnect() {
        let socks = TestServers.freePort(), origin = TestServers.freePort(), port = TestServers.freePort()
        procs.append(TestServers.python("socks5-server.py", [String(socks)]))
        procs.append(TestServers.originServer(port: origin))
        XCTAssertTrue(TestServers.waitForPort(socks)); XCTAssertTrue(TestServers.waitForPort(origin))
        let b = HTTPProxyBridge(port: port) { socks }; bridge = b; b.start()
        XCTAssertTrue(TestServers.waitForPort(port))

        // 30 complete requests, plus 10 clients that connect, send a CONNECT,
        // then vanish mid-relay -- the pattern that leaked.
        for _ in 0..<30 { _ = TestServers.curl(["-x", "http://127.0.0.1:\(port)", "http://127.0.0.1:\(origin)/hello.txt"]) }
        for _ in 0..<10 {
            _ = TestServers.curl(["-m", "1", "-p", "-x", "http://127.0.0.1:\(port)", "http://127.0.0.1:\(origin)/hello.txt",
                                  "--limit-rate", "1"])   // slow, then killed by -m 1
        }
        let deadline = Date().addingTimeInterval(8)
        var remaining = openSockets(toPort: port)
        while Date() < deadline, remaining > 0 { Thread.sleep(forTimeInterval: 0.25); remaining = openSockets(toPort: port) }
        XCTAssertEqual(remaining, 0, "\(remaining) relayed connections still held after all clients left")
    }
}
