import Foundation

/// A proxy endpoint the switch points at.
///
/// Siphon ships with no servers of its own: the menu offers whatever is already
/// configured on this Mac's network services plus whatever the user has typed,
/// so no site-specific hostname lives in the source.
public struct ProxyServer: Equatable, Hashable, Codable, Sendable {
    public let host: String
    public let port: Int

    /// What an omitted port means in the Custom… field. Squid's conventional
    /// port, not a Siphon-specific choice.
    public static let defaultPort = 3128

    public init(host: String, port: Int) {
        self.host = host
        self.port = port
    }

    public var display: String { "\(host):\(port)" }

    /// Parses `host` or `host:port`. Returns nil for anything that would not
    /// survive a round trip through `networksetup` or `scutil`.
    public static func parse(_ text: String, defaultPort: Int = ProxyServer.defaultPort) -> ProxyServer? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        let host: String
        let port: Int
        if let colon = trimmed.lastIndex(of: ":") {
            host = String(trimmed[trimmed.startIndex..<colon])
            let portText = String(trimmed[trimmed.index(after: colon)...])
            guard let parsed = Int(portText) else { return nil }
            port = parsed
        } else {
            host = trimmed
            port = defaultPort
        }

        guard isValidHost(host), (1...65535).contains(port) else { return nil }
        return ProxyServer(host: host, port: port)
    }

    /// Hostname or IPv4 literal. Deliberately strict — these strings become
    /// command arguments and `scutil` dictionary values, and a host that needs
    /// quoting or escaping is a host we do not want to write.
    public static func isValidHost(_ host: String) -> Bool {
        guard (1...253).contains(host.count) else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 1 else { return false }
        return labels.allSatisfy { label in
            guard (1...63).contains(label.count),
                  label.first != "-", label.last != "-" else { return false }
            return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }
}
