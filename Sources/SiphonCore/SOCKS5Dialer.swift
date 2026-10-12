import Foundation
import Network

/// Opens a TCP connection to `host:port` through a local SOCKS5 server.
public enum SOCKS5Dialer {
    public struct Dialed {
        public let connection: NWConnection
        /// Bytes the server sent after its reply, if any. Belong to the stream.
        public let leftover: Data
    }

    public enum DialError: Error {
        case timeout
        case closed
        case transport(NWError)
        case socks(SOCKS5.Error)
    }

    public static func dial(socksPort: UInt16, host: String, port: UInt16,
                            timeout: TimeInterval = 15, queue: DispatchQueue,
                            completion: @escaping (Result<Dialed, DialError>) -> Void) {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: socksPort)!, using: .tcp)
        var finished = false
        func finish(_ result: Result<Dialed, DialError>) {
            guard !finished else { return }
            finished = true
            if case .failure = result { connection.cancel() }
            completion(result)
        }
        let deadline = DispatchWorkItem { finish(.failure(.timeout)) }
        queue.asyncAfter(deadline: .now() + timeout, execute: deadline)

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                handshake(connection, host: host, port: port, queue: queue) { result in
                    deadline.cancel()
                    finish(result)
                }
            case .failed(let error):
                deadline.cancel(); finish(.failure(.transport(error)))
            case .cancelled:
                deadline.cancel(); finish(.failure(.closed))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    private static func handshake(_ c: NWConnection, host: String, port: UInt16, queue: DispatchQueue,
                                  completion: @escaping (Result<Dialed, DialError>) -> Void) {
        c.send(content: SOCKS5.greeting, completion: .contentProcessed { error in
            if let error { return completion(.failure(.transport(error))) }
            c.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                if let error { return completion(.failure(.transport(error))) }
                guard let data else { return completion(.failure(.closed)) }
                do { try SOCKS5.checkGreetingReply(data) } catch let e as SOCKS5.Error {
                    return completion(.failure(.socks(e)))
                } catch { return completion(.failure(.closed)) }
                let request: Data
                do { request = try SOCKS5.connectRequest(host: host, port: port) } catch let e as SOCKS5.Error {
                    return completion(.failure(.socks(e)))
                } catch { return completion(.failure(.closed)) }
                c.send(content: request, completion: .contentProcessed { error in
                    if let error { return completion(.failure(.transport(error))) }
                    readReply(c, buffer: Data(), completion: completion)
                })
            }
        })
    }

    /// The reply's length depends on its address type, so read until the
    /// parser says it is whole.
    private static func readReply(_ c: NWConnection, buffer: Data,
                                  completion: @escaping (Result<Dialed, DialError>) -> Void) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 512) { data, _, isComplete, error in
            if let error { return completion(.failure(.transport(error))) }
            var buffer = buffer
            if let data { buffer.append(data) }
            do {
                switch try SOCKS5.parseConnectReply(buffer) {
                case .connected(let consumed):
                    completion(.success(Dialed(connection: c, leftover: buffer.dropFirst(consumed))))
                case .needMore:
                    if isComplete { completion(.failure(.closed)) } else { readReply(c, buffer: buffer, completion: completion) }
                }
            } catch let e as SOCKS5.Error {
                completion(.failure(.socks(e)))
            } catch { completion(.failure(.closed)) }
        }
    }
}
