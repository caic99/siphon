import Foundation

public struct TunnelConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var target: String
    public var socksPort: UInt16
    /// This tunnel's own HTTP proxy port. Each tunnel is a separate proxy the
    /// system can be pointed at; nothing is balanced across them.
    public var httpPort: UInt16
    public var enabled: Bool

    public init(id: UUID, target: String, socksPort: UInt16, httpPort: UInt16, enabled: Bool) {
        self.id = id; self.target = target; self.socksPort = socksPort
        self.httpPort = httpPort; self.enabled = enabled
    }

    // Configs written before per-tunnel HTTP ports have none; 0 means "assign".
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        target = try c.decode(String.self, forKey: .target)
        socksPort = try c.decode(UInt16.self, forKey: .socksPort)
        httpPort = try c.decodeIfPresent(UInt16.self, forKey: .httpPort) ?? 0
        enabled = try c.decode(Bool.self, forKey: .enabled)
    }
}

/// The set of SSH tunnels, each with its own `ssh -N -D` process and its own
/// loopback HTTP proxy in front of it.
///
/// One proxy per tunnel, deliberately: the system proxy points at exactly one
/// host at a time, so where traffic exits is never a question, and a tunnel
/// that is down takes nothing with it except its own address. Several tunnels
/// can be up at once; switching between them is picking a different server.
public final class TunnelManager {
    public static let defaultHTTPBasePort: UInt16 = 7890
    public static let defaultSOCKSBasePort: UInt16 = 18081
    /// Where allocation starts. Tests point these at free ranges.
    public var httpBasePort: UInt16 = TunnelManager.defaultHTTPBasePort
    public var socksBasePort: UInt16 = TunnelManager.defaultSOCKSBasePort

    private enum Key { static let configs = "sshTunnels" }

    private struct Live {
        let tunnel: SSHTunnel
        let bridge: HTTPProxyBridge
    }

    private let defaults: UserDefaults
    private let sshPath: String
    private let registry: ChildRegistry
    private var live: [UUID: Live] = [:]

    /// Fired on the main queue whenever a tunnel's state or a bridge changes.
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

    /// The address a tunnel's proxy has, whether or not it is listening.
    public func proxyAddress(for config: TunnelConfig) -> ProxyServer {
        ProxyServer(host: "127.0.0.1", port: Int(config.httpPort), socksPort: Int(config.socksPort))
    }

    /// The address clients can use right now; nil until its bridge listens.
    public func proxyServer(for id: UUID) -> ProxyServer? {
        guard let config = configs.first(where: { $0.id == id }),
              live[id]?.bridge.isListening == true else { return nil }
        return proxyAddress(for: config)
    }

    /// The tunnel a server address belongs to, if any.
    public func tunnel(forProxy server: ProxyServer?) -> TunnelConfig? {
        guard let server, server.host == "127.0.0.1" else { return nil }
        return configs.first { Int($0.httpPort) == server.port }
    }

    public func isTunnelProxy(_ server: ProxyServer?) -> Bool { tunnel(forProxy: server) != nil }

    public func bridgeError(for id: UUID) -> String? { live[id]?.bridge.lastError }

    /// What is sitting on a tunnel's HTTP port, for the error message.
    public func bridgePortOwner(for id: UUID) -> String? {
        guard let config = configs.first(where: { $0.id == id }) else { return nil }
        return Self.listenerDescription(port: config.httpPort)
    }

    /// The kept port has since been taken: pick the next free one, persist it
    /// and restart that tunnel's bridge. Returns the new port.
    @discardableResult
    public func moveBridgeToFreePort(_ id: UUID) -> UInt16? {
        guard var list = Optional(configs), let i = list.firstIndex(where: { $0.id == id }) else { return nil }
        let used = Set(list.map(\.httpPort))
        var port = list[i].httpPort &+ 1
        while used.contains(port) || !Self.portIsFree(port) { port += 1 }
        list[i].httpPort = port
        configs = list
        if let l = live[id] {
            l.bridge.stop()
            live[id] = Live(tunnel: l.tunnel, bridge: makeBridge(for: list[i], tunnel: l.tunnel))
        }
        notify()
        return port
    }

    // MARK: - Lifecycle

    /// Launch whatever was enabled last time. Call once at app start.
    public func start() {
        registry.reapLeftovers()   // children of an instance that died uncleanly
        assignMissingHTTPPorts()
        for config in configs where config.enabled { launch(config) }
    }

    /// Synchronous: safe to call immediately before the process exits.
    public func stopAll() {
        for l in live.values { l.tunnel.stopNow(); l.bridge.stop() }
        live.removeAll()
    }

    @discardableResult
    public func add(target: String) -> TunnelConfig {
        let config = TunnelConfig(id: UUID(), target: target.trimmingCharacters(in: .whitespaces),
                                  socksPort: nextPort(from: socksBasePort, avoiding: configs.map(\.socksPort)),
                                  httpPort: nextPort(from: httpBasePort, avoiding: configs.map(\.httpPort)),
                                  enabled: true)
        configs.append(config)
        launch(config)
        notify()
        return config
    }

    public func remove(_ id: UUID) {
        stop(id)
        configs.removeAll { $0.id == id }
        notify()
    }

    public func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = configs.firstIndex(where: { $0.id == id }) else { return }
        var list = configs
        list[index].enabled = enabled
        configs = list
        if enabled { launch(list[index]) } else { stop(id) }
        notify()
    }

    public func retry(_ id: UUID) { live[id]?.tunnel.retry() }

    /// The default route moved: live sessions are stale, give-ups deserve a
    /// fresh start.
    public func networkChanged() {
        for l in live.values {
            if case .gaveUp = l.tunnel.state { l.tunnel.retry() } else { l.tunnel.restart() }
        }
    }

    // MARK: - State

    public func state(of id: UUID) -> SSHTunnel.State { live[id]?.tunnel.state ?? .idle }
    public func connectedSince(_ id: UUID) -> Date? { live[id]?.tunnel.connectedSince }
    public func hasGivenUp(_ id: UUID) -> Bool {
        if case .gaveUp = state(of: id) { return true }
        return false
    }
    public var enabledCount: Int { configs.filter(\.enabled).count }
    public var connectedCount: Int { live.values.filter { $0.tunnel.state == .connected }.count }

    // MARK: - Internals

    private func launch(_ config: TunnelConfig) {
        stop(config.id)
        var config = config
        // Ports kept from last time may have been taken since -- by tunnelmux,
        // another instance, anything. For SOCKS, ssh would fail to bind, or
        // worse the readiness probe would see the stranger's listener and call
        // it connected; those ports are internal, so just move. The HTTP port
        // is user-facing (exports, system proxy) and is only reported.
        if !Self.portIsFree(config.socksPort) {
            config.socksPort = nextPort(from: socksBasePort, avoiding: configs.map(\.socksPort))
            update(config)
        }
        let tunnel = SSHTunnel(target: config.target, socksPort: config.socksPort, sshPath: sshPath,
                               registry: registry)
        tunnel.onChange = { [weak self] in self?.notify() }
        let bridge = makeBridge(for: config, tunnel: tunnel)
        live[config.id] = Live(tunnel: tunnel, bridge: bridge)
        tunnel.start()
    }

    private func stop(_ id: UUID) {
        guard let l = live.removeValue(forKey: id) else { return }
        l.tunnel.stop()
        l.bridge.stop()
    }

    /// A bridge serves exactly its own tunnel: 503 while that tunnel is down,
    /// never a quiet detour through another one.
    private func makeBridge(for config: TunnelConfig, tunnel: SSHTunnel) -> HTTPProxyBridge {
        let bridge = HTTPProxyBridge(port: config.httpPort) { [weak tunnel] in
            guard let tunnel, tunnel.state == .connected else { return nil }
            return tunnel.socksPort
        }
        bridge.onStateChange = { [weak self] in self?.notify() }
        bridge.start()
        return bridge
    }

    private func update(_ config: TunnelConfig) {
        var list = configs
        if let i = list.firstIndex(where: { $0.id == config.id }) { list[i] = config; configs = list }
    }

    private func assignMissingHTTPPorts() {
        var list = configs
        var changed = false
        for i in list.indices where list[i].httpPort == 0 {
            list[i].httpPort = nextPort(from: httpBasePort, avoiding: list.map(\.httpPort))
            changed = true
        }
        if changed { configs = list }
    }

    private func nextPort(from base: UInt16, avoiding taken: [UInt16]) -> UInt16 {
        let used = Set(taken)
        var port = base
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

    static func listenerDescription(port: UInt16) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fcp"]
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

    private func notify() { DispatchQueue.main.async { [onChange] in onChange?() } }
}
