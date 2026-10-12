import Foundation

/// The first thing a client sends to an HTTP proxy, parsed just far enough to
/// know where to tunnel it. Pure: bytes in, decision out.
public struct HTTPProxyRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `CONNECT host:port` — open a raw tunnel (this is how HTTPS goes).
        case connect(host: String, port: UInt16)
        /// A plain request with an absolute URI. `head` is the rewritten request
        /// head to send to the origin: origin-form path, hop-by-hop proxy
        /// headers removed, `Connection: close`.
        case plain(host: String, port: UInt16, head: Data)
    }

    public let kind: Kind

    public enum ParseError: Error, Equatable {
        case malformedRequestLine
        case unsupportedTarget
        case headTooLarge
    }

    static let crlfcrlf = Data("\r\n\r\n".utf8)
    /// Request heads larger than this are refused rather than buffered.
    public static let maxHeadBytes = 64 * 1024

    /// The index just past the blank line ending the head, if it has arrived.
    public static func headEnd(in buffer: Data) -> Int? {
        guard let range = buffer.range(of: crlfcrlf) else { return nil }
        return range.upperBound
    }

    public static func parse(_ head: Data) throws -> HTTPProxyRequest {
        guard head.count <= maxHeadBytes else { throw ParseError.headTooLarge }
        guard let text = String(data: head, encoding: .utf8) ?? String(data: head, encoding: .isoLatin1)
        else { throw ParseError.malformedRequestLine }
        var lines = text.components(separatedBy: "\r\n")
        // A trailing "" or two from the terminating CRLFCRLF.
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let requestLine = lines.first else { throw ParseError.malformedRequestLine }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3 else { throw ParseError.malformedRequestLine }
        let method = parts[0].uppercased(), target = String(parts[1]), version = String(parts[2])
        guard version.hasPrefix("HTTP/") else { throw ParseError.malformedRequestLine }
        let headers = lines.dropFirst()

        if method == "CONNECT" {
            guard let (host, port) = splitHostPort(target, defaultPort: 443) else {
                throw ParseError.unsupportedTarget
            }
            return HTTPProxyRequest(kind: .connect(host: host, port: port))
        }

        // Proxies receive absolute URIs: GET http://host:port/path HTTP/1.1
        guard let url = URLComponents(string: target), let scheme = url.scheme?.lowercased(),
              scheme == "http", let host = url.host, !host.isEmpty
        else { throw ParseError.unsupportedTarget }
        let port = UInt16(url.port ?? 80)
        var path = url.percentEncodedPath.isEmpty ? "/" : url.percentEncodedPath
        if let query = url.percentEncodedQuery { path += "?" + query }

        var out = "\(method) \(path) \(version)\r\n"
        var sawHost = false
        for line in headers {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            // Hop-by-hop headers addressed to us, not the origin.
            if name.hasPrefix("proxy-") || name == "connection" || name == "keep-alive" { continue }
            if name == "host" { sawHost = true }
            out += line + "\r\n"
        }
        if !sawHost {
            out += "Host: " + host + (port == 80 ? "" : ":\(port)") + "\r\n"
        }
        // One request per connection keeps the relay stateless.
        out += "Connection: close\r\n\r\n"
        return HTTPProxyRequest(kind: .plain(host: host, port: port, head: Data(out.utf8)))
    }

    /// "host:port", "[v6]:port", or bare host.
    static func splitHostPort(_ text: String, defaultPort: UInt16) -> (String, UInt16)? {
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { return nil }
            let host = String(text[text.index(after: text.startIndex)..<close])
            let rest = text[text.index(after: close)...]
            if rest.isEmpty { return (host, defaultPort) }
            guard rest.hasPrefix(":"), let port = UInt16(rest.dropFirst()) else { return nil }
            return (host, port)
        }
        guard let colon = text.lastIndex(of: ":") else {
            return text.isEmpty ? nil : (text, defaultPort)
        }
        let host = String(text[..<colon])
        guard !host.isEmpty, let port = UInt16(text[text.index(after: colon)...]) else { return nil }
        return (host, port)
    }
}
