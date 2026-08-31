import Foundation

/// Menu labels for a list of proxy servers.
///
/// A menu is only as wide as its widest row, and fully-qualified proxy names
/// are usually the widest thing in one. Dropping the domain buys most of that
/// width back — but only when the short forms stay unique, otherwise two
/// servers in different domains would render identically.
public enum ServerLabels {
    public static func labels(for servers: [ProxyServer]) -> [String] {
        let short = servers.map(shorten)
        guard Set(short).count == servers.count else { return servers.map(\.display) }
        return short
    }

    private static func shorten(_ server: ProxyServer) -> String {
        let labels = server.host.split(separator: ".")
        // An IP literal has nothing to drop — "127" is not a shorter 127.0.0.1.
        let isIPv4 = labels.count == 4 && labels.allSatisfy { $0.allSatisfy(\.isNumber) }
        guard !isIPv4, labels.count > 1, let first = labels.first else { return server.display }
        return "\(first):\(server.port)"
    }
}
