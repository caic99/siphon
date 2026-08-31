import Foundation

/// Why the live state does not match the switch.
public enum Obstruction: Equatable, Sendable {
    /// The write needs an admin prompt, so it waits for a click.
    case awaitingUser(ProxyIntent)
    /// Someone else's proxy is enabled on this service.
    case foreignProxy(ProxyServer?)
    /// The privileged write was attempted and failed. Distinct from
    /// `awaitingUser` so the menu doesn't claim a password is all that's needed.
    case failed(ProxyIntent, String)
}

/// The switch, its persistence, and the reconciliation between what the user
/// asked for and what the system actually reports.
///
/// Three facts are kept distinct and never conflated: `desiredOn` (the switch
/// position, persisted), the live dictionary read back from SystemConfiguration,
/// and the primary service. The UI renders the live read; `desiredOn` only
/// drives what to write next.
public final class ProxyController {
    private enum Key {
        static let desiredOn = "desiredOn"
        static let selectedServer = "selectedServer"
        static let customServers = "customServers"
        static let reapply = "reapplyOnNetworkChange"
        static let touched = "touchedServices"
    }

    private let defaults: UserDefaults
    private let runner: PrivilegeRunner
    private let monitor = NetworkMonitor()

    public var onChange: (() -> Void)?
    public var onError: ((String) -> Void)?

    public private(set) var primary: PrimaryService?
    public private(set) var current: ProxyDictionary?
    public private(set) var obstruction: Obstruction?
    public private(set) var knownServers: [ProxyServer] = []

    public init(defaults: UserDefaults = .standard, runner: PrivilegeRunner = PrivilegeRunner()) {
        self.defaults = defaults
        self.runner = runner
    }

    // MARK: - Persisted settings

    public private(set) var desiredOn: Bool {
        get { defaults.bool(forKey: Key.desiredOn) }
        set { defaults.set(newValue, forKey: Key.desiredOn) }
    }

    /// On unless the user unchecked it.
    public var reapplyOnNetworkChange: Bool {
        get {
            defaults.object(forKey: Key.reapply) == nil ? true : defaults.bool(forKey: Key.reapply)
        }
        set {
            defaults.set(newValue, forKey: Key.reapply)
            onChange?()
        }
    }

    public private(set) var server: ProxyServer? {
        get { decode(ProxyServer.self, Key.selectedServer) }
        set { encode(newValue, Key.selectedServer) }
    }

    private var customServers: [ProxyServer] {
        get { decode([ProxyServer].self, Key.customServers) ?? [] }
        set { encode(newValue, Key.customServers) }
    }

    /// Services Siphon has proxied, so turning the switch off can clear all of
    /// them — not just the current one. Without this a proxy lingers on Wi-Fi
    /// after the route has moved to Ethernet.
    private var touched: [ProxyTarget] {
        get { decode([ProxyTarget].self, Key.touched) ?? [] }
        set { encode(newValue, Key.touched) }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func encode<T: Encodable>(_ value: T?, _ key: String) {
        guard let value, let data = try? JSONEncoder().encode(value) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }

    // MARK: - Lifecycle

    public func start() {
        monitor.onChange = { [weak self] in self?.handleNetworkChange() }
        monitor.start()
        refreshState()
        refreshServers()
        _ = reconcile(trigger: .automatic)
        onChange?()
    }

    /// Live read. Everything the UI shows comes from here, never from what a
    /// write was expected to accomplish.
    private func refreshState() {
        primary = NetworkState.primaryService()
        current = primary.map { NetworkState.proxies(for: $0) }
    }

    /// The menu's server list: what the user typed, plus what this Mac already
    /// has configured. Keeping the list discovered rather than hard-coded is
    /// why no site-specific hostname appears in Siphon's source.
    private func refreshServers() {
        var servers = customServers
        for discovered in NetworkState.discoverServers() where !servers.contains(discovered) {
            servers.append(discovered)
        }
        if let server, !servers.contains(server) { servers.insert(server, at: 0) }
        knownServers = servers
        // First run: adopt whatever this service is already pointed at, rather
        // than an unrelated proxy that merely sorted first.
        if server == nil { server = current?.server ?? servers.first }
    }

    // MARK: - Commands from the UI

    /// Re-read the world. Called when the menu opens so it never shows a stale
    /// answer after a change Siphon did not make.
    public func refresh() {
        refreshState()
        refreshServers()
        onChange?()
    }


    public var canToggle: Bool { primary != nil && server != nil }

    public var isProxyActive: Bool { current?.isOn ?? false }
    public var activeServer: ProxyServer? { current?.server }

    /// Keyed off the live state, matching how the menu row is labelled: the
    /// click does what the row says, even when the switch disagrees with the Mac.
    public func toggle() { setDesired(!isProxyActive) }

    /// Set the switch directly. Used by the menu's server picker and by the
    /// `--on` / `--off` launch arguments.
    public func setOn(_ on: Bool) { setDesired(on) }

    /// Retry whatever is pending, this time allowed to ask for a password.
    public func resolveObstruction() {
        guard obstruction != nil else { return }
        finish(reconcile(trigger: .userClick), revertingTo: desiredOn)
    }

    public func select(_ newServer: ProxyServer) {
        server = newServer
        if !customServers.contains(newServer), !NetworkState.discoverServers().contains(newServer) {
            customServers.append(newServer)
        }
        refreshServers()
        if desiredOn {
            finish(reconcile(trigger: .userClick), revertingTo: desiredOn)
        } else {
            onChange?()
        }
    }

    private func setDesired(_ on: Bool) {
        let previous = desiredOn
        desiredOn = on
        finish(reconcile(trigger: .userClick), revertingTo: previous)
    }

    /// Cancelling the admin dialog cancels the action, switch included — but
    /// only when the click was a switch change. Backing out of a retry leaves
    /// the mismatch on display rather than pretending it resolved.
    private func finish(_ outcome: PrivilegeOutcome?, revertingTo previous: Bool) {
        if outcome == .cancelled, desiredOn != previous {
            desiredOn = previous
            obstruction = nil
            refreshState()
        }
        onChange?()
    }

    private func handleNetworkChange() {
        refreshState()
        refreshServers()
        if reapplyOnNetworkChange {
            _ = reconcile(trigger: .automatic)
        }
        onChange?()
    }

    // MARK: - Reconciliation

    /// Brings the current service in line with the switch. Returns the outcome
    /// of the privileged write, or nil when none was attempted.
    @discardableResult
    private func reconcile(trigger: ProxyTrigger) -> PrivilegeOutcome? {
        refreshState()
        obstruction = nil
        guard let primary, let current else { return nil }

        let target = ProxyTarget(primary)
        let plan = ProxyPolicy.plan(
            desiredOn: desiredOn,
            server: server,
            current: current,
            serviceIsOurs: touched.contains { $0.serviceID == target.serviceID },
            canRunSilently: runner.canRunSilently([privilegedPath(for: target)]),
            trigger: trigger)

        var outcome: PrivilegeOutcome?
        switch plan {
        case .unavailable:
            break
        case .satisfied:
            // The current service is fine, but an off switch may still owe
            // cleanup on services proxied before the route moved.
            if !desiredOn { outcome = clearTouched(excluding: target, trigger: trigger) }
        case .foreignProxy(let existing):
            obstruction = .foreignProxy(existing)
        case .awaitingUser(let intent):
            obstruction = .awaitingUser(intent)
        case .write(let intent):
            outcome = perform(intent, on: target, trigger: trigger)
        }

        refreshState()
        return outcome
    }

    private func privilegedPath(for target: ProxyTarget) -> String {
        target.isTunnel ? ProxyPolicy.scutil : ProxyPolicy.networksetup
    }

    private func perform(_ intent: ProxyIntent, on target: ProxyTarget,
                         trigger: ProxyTrigger) -> PrivilegeOutcome {
        var targets = [target]
        if case .disable = intent {
            targets += staleTargets(excluding: target)
        }
        let commands = targets.flatMap {
            ProxyPolicy.commands(for: intent, on: $0,
                                 existing: NetworkState.proxies(forKey: $0.proxyKey))
        }
        let outcome = runner.run(commands, allowPrompt: trigger == .userClick)

        switch (outcome, intent) {
        case (.success, .enable):
            if !touched.contains(where: { $0.serviceID == target.serviceID }) {
                touched.append(target)
            }
        case (.success, .disable):
            let cleared = Set(targets.map(\.serviceID))
            touched.removeAll { cleared.contains($0.serviceID) }
        case (.cancelled, _):
            // Still a real mismatch — keep the affordance to retry.
            obstruction = .awaitingUser(intent)
        case (.failure(let message), _):
            obstruction = .failed(intent, message)
            onError?(message)
        }
        return outcome
    }

    /// Clears services proxied earlier that are no longer the primary.
    private func clearTouched(excluding target: ProxyTarget?,
                              trigger: ProxyTrigger) -> PrivilegeOutcome? {
        let stale = staleTargets(excluding: target)
        guard !stale.isEmpty else { return nil }
        guard trigger == .userClick
            || runner.canRunSilently(stale.map(privilegedPath(for:))) else { return nil }

        let commands = stale.flatMap {
            ProxyPolicy.commands(for: .disable, on: $0,
                                 existing: NetworkState.proxies(forKey: $0.proxyKey))
        }
        let outcome = runner.run(commands, allowPrompt: trigger == .userClick)
        if outcome == .success {
            let cleared = Set(stale.map(\.serviceID))
            touched.removeAll { cleared.contains($0.serviceID) }
        }
        return outcome
    }

    /// Touched services that still have a proxy on. Ones already off are
    /// forgotten here — there is nothing left to clear, and a service that has
    /// gone away (a disconnected VPN) must not be resurrected by writing to it.
    private func staleTargets(excluding target: ProxyTarget?) -> [ProxyTarget] {
        var remaining = touched
        var stale: [ProxyTarget] = []
        for candidate in remaining where candidate.serviceID != target?.serviceID {
            if NetworkState.proxies(forKey: candidate.proxyKey).isOn {
                stale.append(candidate)
            } else {
                remaining.removeAll { $0.serviceID == candidate.serviceID }
            }
        }
        touched = remaining
        return stale
    }
}
