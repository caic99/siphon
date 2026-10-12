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
    public static let socksBasePort: UInt16 = 18081

    private enum Key {
        static let configs = "sshTunnels"
        static let httpPort = "tunnelHTTPPort"
    }

    private let defaults: UserDefaults
    private let sshPath: String
    private var tunnels: [UUID: SSHTunnel] = [:]
    private var bridge: HTTPProxyBridge?
    private var roundRobin = 0
    private let lock = NSLock()

    /// Fired on the main queue whenever a tunnel's state or the bridge changes.
    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults, sshPath: String = "/usr/bin/ssh") {
        self.defaults = defaults
        self.sshPath = sshPath
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

    public var httpPort: UInt16 {
        get {
            let stored = defaults.integer(forKey: Key.httpPort)
            return stored > 0 ? UInt16(stored) : Self.defaultHTTPPort
        }
        set {
            defaults.set(Int(newValue), forKey: Key.httpPort)
            if bridge != nil { stopBridge(); startBridgeIfNeeded() }
        }
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
        let tunnel = SSHTunnel(target: config.target, socksPort: config.socksPort, sshPath: sshPath)
        tunnel.onChange = { [weak self] in self?.notify() }
        tunnels[config.id] = tunnel
        tunnel.start()
    }

    private func nextSOCKSPort() -> UInt16 {
        let used = Set(configs.map(\.socksPort))
        var port = Self.socksBasePort
        while used.contains(port) { port += 1 }
        return port
    }

    private func startBridgeIfNeeded() {
        guard bridge == nil, enabledCount > 0 else { return }
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
