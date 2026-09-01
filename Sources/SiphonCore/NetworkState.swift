import Foundation
import SystemConfiguration

/// The network service that owns the default route, and where its proxy
/// settings live.
public struct PrimaryService: Equatable, Sendable {
    public let serviceID: String
    public let interface: String
    /// `UserDefinedName` from the Setup: store — the name `networksetup` takes —
    /// falling back to the interface for tunnels, which have no Setup: entry.
    public let name: String

    public init(serviceID: String, interface: String, name: String) {
        self.serviceID = serviceID
        self.interface = interface
        self.name = name
    }

    /// Tunnel interfaces have no `networksetup` service; their proxies live
    /// in the dynamic State: store and are written with `scutil`.
    public var isTunnel: Bool { Self.isTunnelInterface(interface) }

    public var proxyKey: String {
        "\(isTunnel ? "State" : "Setup"):/Network/Service/\(serviceID)/Proxies"
    }

    /// Tunnels have no Setup: entry, so `name` falls back to the interface —
    /// naming it twice would just be noise.
    public var displayName: String {
        name == interface ? name : "\(name) (\(interface))"
    }

    public static func isTunnelInterface(_ interface: String) -> Bool {
        ["utun", "ppp", "tun", "tap"].contains { interface.hasPrefix($0) }
    }
}

/// Unprivileged reads of the live network configuration. Every call here goes
/// through SystemConfiguration in-process — no subprocesses, unlike the shell
/// script's `route` + `scutil` + `networksetup` pipeline.
public enum NetworkState {
    static let globalIPv4Key = "State:/Network/Global/IPv4"
    static let globalProxiesKey = "State:/Network/Global/Proxies"
    static let serviceProxiesPatterns = [
        "State:/Network/Service/[^/]+/Proxies",
        "Setup:/Network/Service/[^/]+/Proxies",
    ]

    private static func makeStore() -> SCDynamicStore? {
        SCDynamicStoreCreate(nil, "Siphon" as CFString, nil, nil)
    }

    private static func dictionary(_ store: SCDynamicStore, _ key: String) -> [String: Any]? {
        SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }

    /// The service owning the default route. One read replaces the script's
    /// `route -n get default` plus its scan of every service's IPv4 key — and
    /// picks the service that actually owns the route rather than the first one
    /// matching the interface.
    public static func primaryService() -> PrimaryService? {
        guard let store = makeStore(),
              let global = dictionary(store, globalIPv4Key),
              let serviceID = global["PrimaryService"] as? String,
              let interface = global["PrimaryInterface"] as? String
        else { return nil }

        let setup = dictionary(store, "Setup:/Network/Service/\(serviceID)")
        let name = (setup?["UserDefinedName"] as? String) ?? interface
        return PrimaryService(serviceID: serviceID, interface: interface, name: name)
    }

    /// The service's current proxy dictionary. A service with no proxies yet
    /// reads as an empty dictionary, which writes cleanly.
    public static func proxies(for service: PrimaryService) -> ProxyDictionary {
        proxies(forKey: service.proxyKey)
    }

    public static func proxies(forKey key: String) -> ProxyDictionary {
        guard let store = makeStore(), let raw = dictionary(store, key) else {
            return ProxyDictionary()
        }
        return ProxyDictionary(systemDictionary: raw)
    }

    /// Every proxy server already configured on this Mac, most specific first.
    ///
    /// This is where the menu's server list comes from: reading the machine
    /// keeps site-specific hostnames out of Siphon's source while still giving
    /// a useful menu on first launch.
    public static func discoverServers() -> [ProxyServer] {
        guard let store = makeStore() else { return [] }
        var found: [ProxyServer] = []

        var keys: [String] = []
        for pattern in serviceProxiesPatterns {
            let matches = SCDynamicStoreCopyKeyList(store, pattern as CFString) as? [String]
            keys.append(contentsOf: matches ?? [])
        }
        keys.append(globalProxiesKey)

        for key in keys.sorted() {
            guard let raw = dictionary(store, key) else { continue }
            if let server = ProxyDictionary(systemDictionary: raw).server,
               !found.contains(server) {
                found.append(server)
            }
        }
        return found
    }
}
