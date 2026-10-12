import Foundation
import XCTest

/// Helpers for tests that need real local servers.
enum TestServers {
    static var fixtures: URL { Bundle.module.url(forResource: "Fixtures", withExtension: nil)! }

    /// An unused loopback port, found by binding port 0.
    static func freePort() -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, len) } }
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            getsockname(fd, $0, &len) } }
        return UInt16(bigEndian: addr.sin_port)
    }

    static func python(_ script: String, _ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [fixtures.appendingPathComponent(script).path] + args
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()
        return p
    }

    /// `python3 -m http.server` on a temp dir containing hello.txt.
    static func originServer(port: UInt16) -> Process {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("origin-\(port)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try! "hello through the tunnel\n".write(to: dir.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-m", "http.server", "--bind", "127.0.0.1", "--directory", dir.path, String(port)]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try! p.run()
        return p
    }

    static func waitForPort(_ port: UInt16, seconds: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 } }
            close(fd)
            if ok { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Runs curl and returns (status, stdout).
    static func curl(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        // The shell may export no_proxy covering 127.0.0.1, and curl honours it
        // even when -x is given -- which would silently take the bridge out of
        // the test. An empty list disables that.
        p.arguments = ["-s", "-m", "10", "--noproxy", ""] + args
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try! p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
