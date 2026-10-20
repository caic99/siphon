import Foundation

/// Decides when auto re-apply should turn the proxy off because the selected
/// server stopped answering, and on again when it answers. Pure state: the
/// controller feeds it events and carries out the action it returns.
///
/// The rules, in order of precedence:
/// - One failed probe is not enough. It asks for a quick confirmation, and only
///   `failuresToSuspend` failures in a row suspend the proxy, so a single
///   dropped SYN on a busy network does not flip the system proxy.
/// - Suspending is only for a proxy that is on. A switch the user turned off
///   stays off whatever the server does.
/// - A suspended proxy resumes on the first successful probe.
/// - The user has the last word. Turning the proxy on while the server is known
///   to be unreachable is respected until the network changes or the server
///   is seen answering, rather than undone seconds later.
public struct ReachabilityWatchdog: Equatable {
    public enum Action: Equatable {
        case none
        /// Probe again shortly to confirm a first failure.
        case confirmSoon
        /// Turn the proxy off; it is to come back when the server does.
        case suspend
        /// Turn the proxy back on.
        case resume
    }

    public static let failuresToSuspend = 2

    /// True while the proxy is off only because the server stopped answering.
    public private(set) var suspended: Bool
    public private(set) var failures = 0
    public private(set) var userForcedOn = false

    public init(suspended: Bool = false) {
        self.suspended = suspended
    }

    /// A probe of the selected server finished. `proxyOn` is the switch.
    public mutating func probed(reachable: Bool, proxyOn: Bool) -> Action {
        if reachable {
            failures = 0
            userForcedOn = false
            if suspended {
                suspended = false
                return .resume
            }
            return .none
        }
        guard proxyOn, !suspended, !userForcedOn else {
            failures = 0
            return .none
        }
        failures += 1
        guard failures >= Self.failuresToSuspend else { return .confirmSoon }
        failures = 0
        suspended = true
        return .suspend
    }

    /// The user flipped the switch. That ends any suspension.
    public mutating func userSet(on: Bool, serverKnownUnreachable: Bool) {
        suspended = false
        failures = 0
        userForcedOn = on && serverKnownUnreachable
    }

    /// A different server was selected. A suspension carries over, so that the
    /// new server is put in force as soon as it answers.
    public mutating func serverChanged() {
        failures = 0
        userForcedOn = false
    }

    /// The default route moved; whatever the user overrode was about the old
    /// network.
    public mutating func networkChanged() {
        failures = 0
        userForcedOn = false
    }

    /// Auto re-apply was turned off, or the selection is not a plain server.
    public mutating func reset() {
        suspended = false
        failures = 0
        userForcedOn = false
    }
}
