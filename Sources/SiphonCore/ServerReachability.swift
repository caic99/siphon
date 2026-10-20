import Foundation
import Network

/// Answers "is anything listening at this proxy address?" for plain HTTP(S)
/// proxy servers, so their rows can carry a state dot like the tunnel rows.
///
/// A TCP connect is the whole test: the proxy is a service someone else runs,
/// and a port that accepts is the most Siphon can tell without sending traffic
/// through it. Probes go out when asked: the menu opening or the list changing
/// (no more than once per `minimumInterval` per server), and the controller's
/// watch on the selected server while auto re-apply follows it.
public final class ServerReachability {
    public enum Status: Equatable {
        /// Never probed, or the list changed before the first answer.
        case unknown
        case checking
        case reachable(latency: TimeInterval)
        case unreachable(String)
    }

    /// Fired on the main queue whenever any status changes.
    public var onChange: (() -> Void)?
    /// Fired on the main queue for every finished probe, changed or not, so a
    /// caller can count consecutive failures.
    public var onResult: ((ProxyServer, Status) -> Void)?
    public var minimumInterval: TimeInterval = 30
    public var timeout: TimeInterval = 3

    public typealias Prober = (ProxyServer, TimeInterval, @escaping (Status) -> Void) -> Void

    private var statuses: [ProxyServer: Status] = [:]
    private var lastChecked: [ProxyServer: Date] = [:]
    /// Probes out right now. Tracked apart from the status, which keeps showing
    /// the previous answer while a re-probe is out.
    private var inFlight: Set<ProxyServer> = []
    private let prober: Prober
    private let queue = DispatchQueue(label: "com.chucai.siphon.reachability")

    public init(prober: Prober? = nil) {
        self.prober = prober ?? ServerReachability.tcpProbe
    }

    public func status(of server: ProxyServer) -> Status {
        statuses[server] ?? .unknown
    }

    /// Probe each server whose last answer is older than `minimumInterval`
    /// (or every one, when forced). Servers no longer listed are forgotten.
    public func check(_ servers: [ProxyServer], force: Bool = false) {
        let keep = Set(servers)
        statuses = statuses.filter { keep.contains($0.key) }
        lastChecked = lastChecked.filter { keep.contains($0.key) }
        let now = Date()
        for server in servers {
            if !force, let last = lastChecked[server], now.timeIntervalSince(last) < minimumInterval { continue }
            launch(server)
        }
    }

    /// Probe one server now, leaving every other server's status alone.
    public func probe(_ server: ProxyServer) {
        launch(server)
    }

    private func launch(_ server: ProxyServer) {
        guard !inFlight.contains(server) else { return }
        inFlight.insert(server)
        lastChecked[server] = Date()
        // Keep the last answer visible while the new probe is out; a dot
        // that flickers grey on every menu open says nothing useful.
        if case .unknown = status(of: server) { set(server, .checking) }
        prober(server, timeout) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.inFlight.remove(server)
                // A server dropped from the list while its probe was out
                // stays forgotten.
                guard self.statuses[server] != nil else { return }
                self.set(server, result)
                self.onResult?(server, result)
            }
        }
    }

    /// Hand a status in from outside, for pictures and tests.
    public func seed(_ server: ProxyServer, _ status: Status) {
        lastChecked[server] = .distantFuture
        set(server, status)
    }

    private func set(_ server: ProxyServer, _ status: Status) {
        guard statuses[server] != status else { return }
        statuses[server] = status
        onChange?()
    }

    // MARK: - The default probe

    /// Connect straight to host:port, deliberately ignoring the system proxy:
    /// with the proxy on, the system setting points at this very server, and
    /// going through it would test the proxy with itself.
    static func tcpProbe(_ server: ProxyServer, timeout: TimeInterval,
                         completion: @escaping (Status) -> Void) {
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: server.port)), server.port > 0 else {
            completion(.unreachable("invalid port"))
            return
        }
        let params = NWParameters.tcp
        params.preferNoProxies = true
        let connection = NWConnection(host: NWEndpoint.Host(server.host), port: port, using: params)
        let queue = DispatchQueue(label: "com.chucai.siphon.reachability.probe")
        let started = Date()
        var done = false
        func finish(_ status: Status) {
            guard !done else { return }
            done = true
            connection.cancel()
            completion(status)
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish(.unreachable("timed out")) }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                finish(.reachable(latency: Date().timeIntervalSince(started)))
            case .failed(let error):
                finish(.unreachable(Self.describe(error)))
            case .waiting(let error):
                // "Waiting" is Network.framework retrying forever; for a probe
                // that is already the answer.
                finish(.unreachable(Self.describe(error)))
            case .cancelled:
                finish(.unreachable("cancelled"))
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(let code):
            switch code {
            case .ECONNREFUSED: return "connection refused"
            case .EHOSTUNREACH, .ENETUNREACH: return "no route to host"
            case .ETIMEDOUT: return "timed out"
            case .ENETDOWN: return "network down"
            default: return String(cString: strerror(code.rawValue)).lowercased()
            }
        case .dns:
            return "name not resolved"
        default:
            return error.localizedDescription
        }
    }
}
