import Foundation
import Network

/// A loopback HTTP proxy that carries every request over a SOCKS5 server.
///
/// `upstream` is asked for a SOCKS port per request, so the caller can balance
/// across several tunnels and say "none" (→ 503) when nothing is connected.
/// CONNECT becomes a raw relay; a plain absolute-URI request is rewritten to
/// origin-form and relayed the same way. One request per client connection.
public final class HTTPProxyBridge {
    public let port: UInt16
    public private(set) var isListening = false
    public var onStateChange: (() -> Void)?
    /// Set when the listener could not bind — typically the port is taken.
    public private(set) var lastError: String?

    private let upstream: () -> UInt16?
    private let queue = DispatchQueue(label: "siphon.bridge")
    private var listener: NWListener?
    private var connections = Set<ObjectIdentifier>()

    public init(port: UInt16, upstream: @escaping () -> UInt16?) {
        self.port = port
        self.upstream = upstream
    }

    public func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // Loopback only: this proxy must never be reachable from the LAN.
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            let listener: NWListener
            do { listener = try NWListener(using: params) } catch {
                lastError = "\(error)"; notify(); return
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: isListening = true; lastError = nil
                case .failed(let error):
                    isListening = false; lastError = Self.describe(error); self.listener = nil
                case .cancelled: isListening = false
                default: break
                }
                notify()
            }
            listener.newConnectionHandler = { [weak self] client in self?.accept(client) }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            listener?.cancel(); listener = nil
            isListening = false; notify()
        }
    }

    private func notify() { DispatchQueue.main.async { [onStateChange] in onStateChange?() } }

    private static func describe(_ error: NWError) -> String {
        if case .posix(let code) = error, code == .EADDRINUSE { return "port already in use" }
        return "\(error)"
    }

    // MARK: - One client

    private func accept(_ client: NWConnection) {
        client.stateUpdateHandler = { [weak self] state in
            if case .ready = state { self?.readHead(client, buffer: Data()) }
        }
        client.start(queue: queue)
    }

    private func readHead(_ client: NWConnection, buffer: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil { client.cancel(); return }
            guard let end = HTTPProxyRequest.headEnd(in: buffer) else {
                if isComplete || buffer.count > HTTPProxyRequest.maxHeadBytes { client.cancel() }
                else { readHead(client, buffer: buffer) }
                return
            }
            let head = buffer.prefix(end)
            let rest = buffer.dropFirst(end)       // early body / TLS bytes
            let request: HTTPProxyRequest
            do { request = try HTTPProxyRequest.parse(Data(head)) } catch {
                reply(client, "400 Bad Request"); return
            }
            guard let socksPort = upstream() else {
                reply(client, "503 No Tunnel Connected"); return
            }
            let (host, port) = request.kind.destination
            SOCKS5Dialer.dial(socksPort: socksPort, host: host, port: port, queue: queue) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure:
                    reply(client, "502 Bad Gateway")
                case .success(let dialed):
                    let origin = dialed.connection
                    switch request.kind {
                    case .connect:
                        client.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8),
                                    completion: .contentProcessed { _ in })
                    case .plain(_, _, let rewritten):
                        origin.send(content: rewritten, completion: .contentProcessed { _ in })
                    }
                    if !rest.isEmpty { origin.send(content: Data(rest), completion: .contentProcessed { _ in }) }
                    if !dialed.leftover.isEmpty { client.send(content: dialed.leftover, completion: .contentProcessed { _ in }) }
                    pump(from: client, to: origin)
                    pump(from: origin, to: client)
                }
            }
        }
    }

    private func reply(_ client: NWConnection, _ status: String) {
        let body = Data("HTTP/1.1 \(status)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n".utf8)
        // FIN after the bytes, then cancel: cancelling straight from the send
        // completion can drop a response that is still in flight.
        client.send(content: body, contentContext: .finalMessage, isComplete: true,
                    completion: .contentProcessed { _ in client.cancel() })
    }

    /// Copies bytes one way until EOF, then half-closes the far side so the
    /// other pump can drain and finish.
    private func pump(from a: NWConnection, to b: NWConnection) {
        a.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                b.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { a.cancel(); b.cancel(); return }
                    if isComplete || error != nil { b.send(content: nil, isComplete: true, completion: .contentProcessed { _ in }) }
                    else { self?.pump(from: a, to: b) }
                })
            } else if isComplete || error != nil {
                b.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
            } else {
                self?.pump(from: a, to: b)
            }
        }
    }
}

extension HTTPProxyRequest.Kind {
    var destination: (String, UInt16) {
        switch self {
        case .connect(let host, let port): return (host, port)
        case .plain(let host, let port, _): return (host, port)
        }
    }
}
