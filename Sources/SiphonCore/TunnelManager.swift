import Foundation

public struct TunnelConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var target: String
    public var socksPort: UInt16
    public var enabled: Bool
}

/// The set of SSH tunnels and the one HTTP bridge in front of them.
///
/// Mirrors tunnelmux's shape: every tunnel gets its own SOCKS port (18081
/// upward), and a single HTTP proxy on 7890 round-robins each request across
/// whichever tunnels are connected right now. Configuration persists in
/// UserDefaults; processes do not — tunnels are relaunched at startup.
public final class TunnelManager {
    public static let defaultHTTPPort: UInt16 = 7890
    public static let defaultSOCKSBasePort: UInt16 = 18081
    /// Where SOCKS port allocation starts. Tests point this at a free range.
    public var socksBasePort: UInt16 = TunnelManager.defaultSOCKSBasePort

    private enum Key {
        static let configs = "sshTunnels"
        static let httpPort = "tunnelHTTPPort"
    }

    private let defaults: UserDefaults
    private let sshPath: String
    private let registry: ChildRegistry
    private var tunnels: [UUID: SSHTunnel] = [:]
    private var bridge: HTTPProxyBridge?
    private var roundRobin = 0
    private let lock = NSLock()

    /// Fired on the main queue whenever a tunnel's state or the bridge changes.
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults, sshPath: String = "/usr/bin/ssh") {
        self.defaults = defaults
        self.sshPath = sshPath
        self.registry = ChildRegistry(defaults: defaults)
    }

    // MARK: - Configuration

    public private(set) var configs: [TunnelConfig] {
        get {
            guard let data = defaults.data(forKey: Key.configs),
                  let list = try? JSONDecoder().decode([TunnelConfig].self, from: data) else { return [] }
            return list
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: Key.configs) }
    }

    /// The bridge's port. Chosen on first use as the first free port from 7890
    /// (tunnelmux may already hold 7890 itself) and then kept, because exports
    /// and the system proxy refer to it by number.
    public var httpPort: UInt16 {
        get {
            let stored = defaults.integer(forKey: Key.httpPort)
            return stored > 0 ? UInt16(stored) : Self.firstFreePort(from: Self.defaultHTTPPort)
        }
        set {
            defaults.set(Int(newValue), forKey: Key.httpPort)
            if bridge != nil { stopBridge(); startBridgeIfNeeded() }
        }
    }

    /// When the kept port has since been taken, the user chooses to move: this
    /// picks the next free port, persists it and restarts the bridge. Returns
    /// the new port.
    @discardableResult
    public func moveBridgeToFreePort() -> UInt16 {
        let next = Self.firstFreePort(from: httpPort &+ 1)
        httpPort = next
        return next
    }

    /// What is sitting on the bridge's port, for the error message.
    public var bridgePortOwner: String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(httpPort)", "-sTCP:LISTEN", "-Fcp"]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        var pid = "", cmd = ""
        for line in text.split(separator: "\n") {
            if line.hasPrefix("p") { pid = String(line.dropFirst()) }
            if line.hasPrefix("c") { cmd = String(line.dropFirst()) }
        }
        return cmd.isEmpty ? nil : "\(cmd) (pid \(pid))"
    }

    public static func firstFreePort(from start: UInt16) -> UInt16 {
        var port = start
        while !portIsFree(port) && port < UInt16.max { port += 1 }
        return port
    }

    /// The address clients use. Nil until the bridge is actually listening.
    public var proxyServer: ProxyServer? {
        bridge?.isListening == true ? ProxyServer(host: "127.0.0.1", port: Int(httpPort)) : nil
    }

    /// The address regardless of state — for recognising it in a server list.
    public func isTunnelProxy(_ server: ProxyServer?) -> Bool {
        server == ProxyServer(host: "127.0.0.1", port: Int(httpPort))
    }

    public var bridgeError: String? { bridge?.lastError }

    // MARK: - Lifecycle

    /// Launch whatever was enabled last time. Call once at app start.
    public func start() {
        // Children of a previous instance that died without cleaning up.
        registry.reapLeftovers()
        for config in configs where config.enabled { launch(config) }
        startBridgeIfNeeded()
    }

    public func stopAll() {
        tunnels.values.forEach { $0.stop() }
        tunnels.removeAll()
        stopBridge()
    }

    @discardableResult
    public func add(target: String) -> TunnelConfig {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        let config = TunnelConfig(id: UUID(), target: trimmed, socksPort: nextSOCKSPort(), enabled: true)
        configs.append(config)
        launch(config)
        startBridgeIfNeeded()
        notify()
        return config
    }

    public func remove(_ id: UUID) {
        tunnels[id]?.stop()
        tunnels[id] = nil
        configs.removeAll { $0.id == id }
        if enabledCount == 0 { stopBridge() }
        notify()
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        var list = configs
        list[index].enabled = enabled
        configs = list
        if enabled {
            launch(list[index]); startBridgeIfNeeded()
        } else {
            tunnels[id]?.stop(); tunnels[id] = nil
            if enabledCount == 0 { stopBridge() }
        }
        notify()
    }

    public func retry(_ id: UUID) { tunnels[id]?.retry() }

    /// The default route moved: live sessions are stale, give-ups deserve a
    /// fresh start.
    public func networkChanged() {
        for (id, tunnel) in tunnels {
            if case .gaveUp = tunnel.state { tunnel.retry() } else { tunnel.restart() }
            _ = id
        }
    }

    // MARK: - State

    public func state(of id: UUID) -> SSHTunnel.State { tunnels[id]?.state ?? .idle }
    public func connectedSince(_ id: UUID) -> Date? { tunnels[id]?.connectedSince }
    public var enabledCount: Int { configs.filter(\.enabled).count }
    public var connectedCount: Int { tunnels.values.filter { $0.state == .connected }.count }

    /// Nothing is connected and nothing is still trying — tunnelmux's trigger
    /// for taking the system proxy down.
    public var allGaveUp: Bool {
        guard enabledCount > 0, connectedCount == 0 else { return false }
        return tunnels.values.allSatisfy { if case .gaveUp = $0.state { return true }; return false }
    }

    // MARK: - Internals

    private func launch(_ config: TunnelConfig) {
        tunnels[config.id]?.stop()
        var config = config
        // The port kept from last time may have been taken since -- by
        // tunnelmux, another instance, anything. ssh would fail to bind, or
        // worse, the readiness probe would see the stranger's listener and
        // call it connected. SOCKS ports are internal, so just move.
        if !Self.portIsFree(config.socksPort) {
            config.socksPort = nextSOCKSPort()
            var list = configs
            if let i = list.firstIndex(where: { $0.id == config.id }) { list[i] = config; configs = list }
        }
        let tunnel = SSHTunnel(target: config.target, socksPort: config.socksPort, sshPath: sshPath,
                               registry: registry)
        tunnel.onChange = { [weak self] in self?.notify() }
        tunnels[config.id] = tunnel
        tunnel.start()
    }

    /// The first port from the base that no configured tunnel uses and that
    /// nothing on this Mac is listening on — tunnelmux and a previous Siphon
    /// use the same range, so "not ours" is not the same as "free".
    private func nextSOCKSPort() -> UInt16 {
        let used = Set(configs.map(\.socksPort))
        var port = socksBasePort
        while used.contains(port) || !Self.portIsFree(port) { port += 1 }
        return port
    }

    static func portIsFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func startBridgeIfNeeded() {
        guard bridge == nil, enabledCount > 0 else { return }
        if defaults.integer(forKey: Key.httpPort) == 0 {
            defaults.set(Int(httpPort), forKey: Key.httpPort)   // pin the first-use choice
        }
        let b = HTTPProxyBridge(port: httpPort) { [weak self] in self?.pickUpstream() }
        b.onStateChange = { [weak self] in self?.notify() }
        bridge = b
        b.start()
    }

    private func stopBridge() {
        bridge?.stop()
        bridge = nil
        notify()
    }

    /// Round-robin over connected tunnels, in configuration order. Called from
    /// the bridge's queue.
    private func pickUpstream() -> UInt16? {
        lock.lock(); defer { lock.unlock() }
        let ready = configs.compactMap { tunnels[$0.id] }.filter { $0.state == .connected }
        guard !ready.isEmpty else { return nil }
        let chosen = ready[roundRobin % ready.count]
        roundRobin &+= 1
        return chosen.socksPort
    }

    private func notify() { DispatchQueue.main.async { [onChange] in onChange?() } }
}
