import Foundation

/// A network service Siphon can write proxy settings to. Carries enough to
/// clear a service later without re-deriving an interface that may be gone.
public struct ProxyTarget: Codable, Equatable, Hashable, Sendable {
    public let serviceID: String
    public let name: String
    public let isTunnel: Bool

    public init(serviceID: String, name: String, isTunnel: Bool) {
        self.serviceID = serviceID
        self.name = name
        self.isTunnel = isTunnel
    }

    public init(_ service: PrimaryService) {
        self.init(serviceID: service.serviceID, name: service.name, isTunnel: service.isTunnel)
    }

    public var proxyKey: String {
        "\(isTunnel ? "State" : "Setup"):/Network/Service/\(serviceID)/Proxies"
    }
}

public enum ProxyIntent: Equatable, Sendable {
    case enable(ProxyServer)
    case disable
}

public enum ProxyPlan: Equatable, Sendable {
    /// The service already matches the switch position.
    case satisfied
    /// No default route, or no server chosen yet.
    case unavailable
    /// Write now.
    case write(ProxyIntent)
    /// The write is needed, but doing it would pop an admin dialog nobody asked
    /// for. Show it as pending and wait for a click.
    case awaitingUser(ProxyIntent)
    /// A proxy Siphon did not set is enabled here. Refuse to overwrite it
    /// automatically; an explicit click still goes through.
    case foreignProxy(ProxyServer?)
}

public enum ProxyTrigger: Sendable {
    /// The user clicked something, so a password prompt is fair game.
    case userClick
    /// The network moved or the app launched.
    case automatic
}

/// The whole re-apply decision, as one pure function.
public enum ProxyPolicy {
    public static func plan(desiredOn: Bool,
                            server: ProxyServer?,
                            current: ProxyDictionary?,
                            serviceIsOurs: Bool,
                            canRunSilently: Bool,
                            trigger: ProxyTrigger) -> ProxyPlan {
        guard let current else { return .unavailable }

        func gated(_ intent: ProxyIntent) -> ProxyPlan {
            if trigger == .userClick { return .write(intent) }
            return canRunSilently ? .write(intent) : .awaitingUser(intent)
        }

        if desiredOn {
            guard let server else { return .unavailable }
            if current.isOn {
                if current.server == server { return .satisfied }
                if !serviceIsOurs, trigger == .automatic {
                    return .foreignProxy(current.server)
                }
            }
            return gated(.enable(server))
        }

        // Turning off only touches services Siphon proxied — unless the user
        // asked for it directly, in which case they mean this one too.
        if current.isOn, serviceIsOurs || trigger == .userClick {
            return gated(.disable)
        }
        return .satisfied
    }

    static let scutil = "/usr/sbin/scutil"
    static let networksetup = "/usr/sbin/networksetup"

    /// The privileged commands that carry out `intent` on `target`.
    ///
    /// Tunnels get a full dictionary rewrite through `scutil`, built from what
    /// is already there so exception lists survive. Physical services go through
    /// `networksetup`, which only touches the web-proxy keys.
    public static func commands(for intent: ProxyIntent,
                                on target: ProxyTarget,
                                existing: ProxyDictionary) -> [PrivilegedCommand] {
        if target.isTunnel {
            let updated: ProxyDictionary
            switch intent {
            case .enable(let server): updated = existing.enabling(server)
            case .disable: updated = existing.disabled()
            }
            let script = updated.scutilCommands(setting: target.proxyKey).joined(separator: "\n")
            return [PrivilegedCommand(path: scutil, input: script)]
        }

        switch intent {
        case .enable(let server):
            let port = String(server.port)
            return [
                PrivilegedCommand(path: networksetup,
                                  arguments: ["-setwebproxy", target.name, server.host, port]),
                PrivilegedCommand(path: networksetup,
                                  arguments: ["-setsecurewebproxy", target.name, server.host, port]),
            ]
        case .disable:
            return [
                PrivilegedCommand(path: networksetup,
                                  arguments: ["-setwebproxystate", target.name, "off"]),
                PrivilegedCommand(path: networksetup,
                                  arguments: ["-setsecurewebproxystate", target.name, "off"]),
            ]
        }
    }
}
