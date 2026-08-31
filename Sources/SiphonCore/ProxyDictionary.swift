import Foundation

/// A value `scutil`'s dictionary command language (`d.add`) can express.
public enum SCValue: Equatable, Sendable {
    case string(String)
    case number(Int)
    case array([String])
}

/// One network service's `Proxies` dictionary.
///
/// Siphon owns exactly six keys — the HTTP and HTTPS enable flags, hosts, and
/// ports — and carries everything else through untouched: exception lists,
/// `ExcludeSimpleHostnames`, `FTPPassive`, SOCKS. The shell script this app
/// replaces rebuilt the dictionary from scratch on the VPN path and dropped all
/// of it.
public struct ProxyDictionary: Equatable, Sendable {
    public private(set) var entries: [String: SCValue]

    /// Keys skipped while reading because `scutil` cannot express their value —
    /// nested dictionaries, data, or a literal backslash. Preserving the rest of
    /// the dictionary would silently lose these, so callers surface them instead.
    public private(set) var droppedKeys: [String]

    public init(entries: [String: SCValue] = [:], droppedKeys: [String] = []) {
        self.entries = entries
        self.droppedKeys = droppedKeys.sorted()
    }

    private enum Key {
        static let httpEnable = "HTTPEnable"
        static let httpProxy = "HTTPProxy"
        static let httpPort = "HTTPPort"
        static let httpsEnable = "HTTPSEnable"
        static let httpsProxy = "HTTPSProxy"
        static let httpsPort = "HTTPSPort"
    }

    // MARK: - Reading

    /// Adopts a dictionary as returned by `SCDynamicStoreCopyValue`.
    public init(systemDictionary: [String: Any]) {
        var entries: [String: SCValue] = [:]
        var dropped: [String] = []
        for (key, value) in systemDictionary {
            if let converted = Self.convert(value) {
                entries[key] = converted
            } else {
                dropped.append(key)
            }
        }
        self.init(entries: entries, droppedKeys: dropped)
    }

    private static func convert(_ value: Any) -> SCValue? {
        if let number = value as? NSNumber, !(value is String) {
            // CFBoolean bridges to NSNumber too; macOS stores these flags as
            // integers and reads them back the same way.
            return .number(number.intValue)
        }
        if let string = value as? String {
            return isRepresentable(string) ? .string(string) : nil
        }
        if let array = value as? [Any] {
            var strings: [String] = []
            for element in array {
                guard let string = element as? String, isRepresentable(string) else { return nil }
                strings.append(string)
            }
            return .array(strings)
        }
        return nil
    }

    /// `scutil` honours `\"` inside a quoted value but has no escape for a
    /// literal backslash, so a value carrying one cannot be written back.
    private static func isRepresentable(_ value: String) -> Bool {
        !value.contains("\\")
    }

    /// True when HTTP proxying is on — the same flag the shell script tested.
    public var isOn: Bool { entries[Key.httpEnable] == .number(1) }

    /// The configured HTTP proxy, whether or not it is enabled.
    public var server: ProxyServer? {
        guard case .string(let host)? = entries[Key.httpProxy],
              case .number(let port)? = entries[Key.httpPort] else { return nil }
        return ProxyServer(host: host, port: port)
    }

    // MARK: - Editing

    public func enabling(_ server: ProxyServer) -> ProxyDictionary {
        var copy = self
        copy.entries[Key.httpEnable] = .number(1)
        copy.entries[Key.httpProxy] = .string(server.host)
        copy.entries[Key.httpPort] = .number(server.port)
        copy.entries[Key.httpsEnable] = .number(1)
        copy.entries[Key.httpsProxy] = .string(server.host)
        copy.entries[Key.httpsPort] = .number(server.port)
        return copy
    }

    /// Mirrors `networksetup -setwebproxystate off`: clears the enable flags and
    /// leaves host and port in place, so re-enabling by hand keeps the server.
    public func disabled() -> ProxyDictionary {
        var copy = self
        copy.entries[Key.httpEnable] = .number(0)
        copy.entries[Key.httpsEnable] = .number(0)
        return copy
    }

    // MARK: - Writing

    /// The `scutil` script that replaces `key` with this dictionary. Keys are
    /// emitted in sorted order so the output is reproducible and diffable.
    public func scutilCommands(setting key: String) -> [String] {
        var lines = ["d.init"]
        for name in entries.keys.sorted() {
            switch entries[name]! {
            case .string(let value):
                lines.append("d.add \(name) \(Self.quote(value))")
            case .number(let value):
                lines.append("d.add \(name) # \(value)")
            case .array(let values):
                let quoted = values.map(Self.quote).joined(separator: " ")
                lines.append("d.add \(name) *" + (quoted.isEmpty ? "" : " " + quoted))
            }
        }
        lines.append("set \(key)")
        return lines
    }

    /// `scutil` splits unquoted values on whitespace, so every string is quoted.
    /// Backslashes never reach here — values containing one are dropped on read.
    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
