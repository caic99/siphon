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
        static let suspendedUnreachable = "suspendedForUnreachableServer"
    }

    /// How often the selected server is probed while auto re-apply follows
    /// it: the steady check, the faster one while waiting for it to return,
    /// and the delay before confirming a first failure.
    public var watchInterval: TimeInterval = 15
    public var suspendedWatchInterval: TimeInterval = 10
    public var confirmDelay: TimeInterval = 3

    private let defaults: UserDefaults
    private let runner: PrivilegeRunner
    private let monitor = NetworkMonitor()
    public let tunnels: TunnelManager
    /// Set when the switch was turned off *for* the tunnels going down, so it
    /// is turned back on when one returns — and only then.
    private var suspendedForTunnels = false
    /// Which service owned the default route at the last look. The monitor also
    /// fires on proxy-key changes — including Siphon's own writes — and those
    /// must not restart ssh sessions; only a genuinely new route should.
    private var lastRouteOwner: String?

    /// Probes plain proxy servers; the menu's dots read it too.
    public let reachability: ServerReachability
    /// Fired when any server's reachability changes, for the dots. Kept apart
    /// from `onChange` so a probe answering does not rebuild the open menu.
    public var onReachabilityChange: (() -> Void)?
    /// Follows the selected plain server while auto re-apply is on. Its
    /// suspension is persisted: a proxy paused for an unreachable server must
    /// still come back after a relaunch.
    private var watchdog: ReachabilityWatchdog {
        didSet { defaults.set(watchdog.suspended, forKey: Key.suspendedUnreachable) }
    }
    private var watchedServer: ProxyServer?
    private var watchTimer: DispatchSourceTimer?
    private var watchTimerInterval: TimeInterval = 0
    private var confirmation: DispatchWorkItem?
    private var started = false

    public var onChange: (() -> Void)?
    public var onError: ((String) -> Void)?

    public private(set) var primary: PrimaryService?
    public private(set) var current: ProxyDictionary?
    public private(set) var obstruction: Obstruction?
    public private(set) var knownServers: [ProxyServer] = []

    /// Both the .app and the bare binary must read the same switch position;
    /// an unbundled process would otherwise get its own domain keyed on the
    /// executable name, so `--on` and the menu would disagree. Passing the
    /// bundle identifier as a suite name is a no-op inside the bundle (it
    /// already is that domain) and redirects the unbundled case onto it.
    public static let defaultsDomain = "com.chucai.siphon"

    /// Inside the app bundle this domain already *is* `standard`; passing it as
    /// a suite name there is a no-op AppKit logs a complaint about.
    public static func sharedDefaults() -> UserDefaults {
        if Bundle.main.bundleIdentifier == defaultsDomain { return .standard }
        return UserDefaults(suiteName: defaultsDomain) ?? .standard
    }

    /// Discovery reads the proxies configured on this Mac. Off, the menu lists
    /// only what has been added explicitly — which is how the README screenshot
    /// is produced without a real hostname in it.
    private let discoversServers: Bool

    public init(defaults: UserDefaults = ProxyController.sharedDefaults(),
                runner: PrivilegeRunner = PrivilegeRunner(),
                discoversServers: Bool = true,
                sshPath: String = "/usr/bin/ssh",
                reachabilityProber: ServerReachability.Prober? = nil) {
        self.defaults = defaults
        self.runner = runner
        self.discoversServers = discoversServers
        self.tunnels = TunnelManager(defaults: defaults, sshPath: sshPath)
        self.reachability = ServerReachability(prober: reachabilityProber)
        self.watchdog = ReachabilityWatchdog(suspended: defaults.bool(forKey: Key.suspendedUnreachable))
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
            // Turning it off ends a pause without turning the proxy back on:
            // the server is still unreachable, and auto is what was asked to stop.
            if !newValue { watchdog.reset() }
            updateWatch(probeNow: newValue)
            onChange?()
        }
    }

    public private(set) var server: ProxyServer? {
        get {
            guard let stored = decode(ProxyServer.self, Key.selectedServer) else { return nil }
            // Tunnels carry a SOCKS port that is not persisted; look it up.
            if let config = tunnels.tunnel(forProxy: stored) { return tunnels.proxyAddress(for: config) }
            return stored
        }
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
        tunnels.onChange = { [weak self] in self?.tunnelsChanged() }
        tunnels.start()
        refreshState()
        lastRouteOwner = primary.map { "\($0.serviceID)|\($0.interface)" }
        refreshServers()
        _ = reconcile(trigger: .automatic)
        reachability.onChange = { [weak self] in self?.onReachabilityChange?() }
        reachability.onResult = { [weak self] server, status in self?.probeFinished(server, status) }
        started = true
        updateWatch(probeNow: true)
        onChange?()
    }

    /// Call at quit: ssh children must not outlive the app.
    public func shutdown() {
        watchTimer?.cancel()
        tunnels.stopAll()
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
        if discoversServers {
            for discovered in NetworkState.discoverServers() where !servers.contains(discovered) {
                servers.append(discovered)
            }
        }
        if let server, !servers.contains(server) { servers.insert(server, at: 0) }
        // Tunnels have their own rows; their addresses must not also appear as
        // plain servers. This runs last because discovery reads the system
        // proxy settings back, and when the system points at a tunnel that is
        // exactly where its address comes from.
        servers.removeAll { tunnels.isTunnelProxy($0) }
        knownServers = servers
        // First run: adopt what this service is already pointed at. Waiting for
        // a service beats guessing from an unrelated discovered proxy that
        // merely sorted first.
        if server == nil, let current {
            server = current.server ?? servers.first
            if let server { remember(server) }
        }
    }

    private func remember(_ newServer: ProxyServer) {
        guard !customServers.contains(newServer), !tunnels.isTunnelProxy(newServer) else { return }
        customServers.append(newServer)
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

    /// The server exports should describe: what is actually in force, falling
    /// back to the selection when the proxy is off. When the live address is
    /// the selected one, the selection is returned, because it is the copy
    /// that carries a tunnel's SOCKS port -- the address read back from the
    /// system does not.
    public var exportServer: ProxyServer? {
        guard let active = activeServer else { return server }
        if let selected = server, selected == active { return selected }
        return tunnels.tunnel(forProxy: active).map(tunnels.proxyAddress(for:)) ?? active
    }

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

    /// Servers the user added, as opposed to discovered on this Mac — the
    /// only ones that can be removed.
    public var addedServers: [ProxyServer] { customServers }

    /// Drop a server the user added. If it was selected, selection falls back
    /// to whatever the current service points at, as on first run.
    public func forgetServer(_ old: ProxyServer) {
        customServers.removeAll { $0 == old }
        if server == old { server = nil }
        refreshServers()
        updateWatch()
        onChange?()
    }

    public func select(_ newServer: ProxyServer) {
        if newServer != server { watchdog.serverChanged() }
        server = newServer
        // Remember every server that gets used, not just typed-in ones.
        // Discovery only sees what is configured *now*, so switching away from
        // a server would otherwise drop it off the menu and there would be no
        // way back to it except retyping it under Custom….
        remember(newServer)
        refreshServers()
        // A pause carries over to a newly picked server, which goes into force
        // when it answers. A tunnel has its own rule, so picking one while
        // paused simply means using it.
        if watchdog.suspended, tunnels.isTunnelProxy(newServer) {
            watchdog.reset()
            desiredOn = true
        }
        updateWatch(probeNow: true)
        if desiredOn {
            finish(reconcile(trigger: .userClick), revertingTo: desiredOn)
        } else {
            onChange?()
        }
    }

    private func setDesired(_ on: Bool) {
        let previous = desiredOn
        suspendedForTunnels = false   // the user decided; stop second-guessing
        watchdog.userSet(on: on, serverKnownUnreachable: selectedServerKnownUnreachable)
        desiredOn = on
        finish(reconcile(trigger: .userClick), revertingTo: previous)
        updateWatch(probeNow: on)
    }

    private var selectedServerKnownUnreachable: Bool {
        guard let server, case .unreachable = reachability.status(of: server) else { return false }
        return true
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
        let owner = primary.map { "\($0.serviceID)|\($0.interface)" }
        if owner != lastRouteOwner {
            lastRouteOwner = owner
            tunnels.networkChanged()
            watchdog.networkChanged()
        }
        refreshServers()
        if reapplyOnNetworkChange {
            _ = reconcile(trigger: .automatic)
        }
        // A network change is the usual reason a proxy comes and goes (a VPN
        // dropping, leaving the office), so ask at once rather than at the
        // next tick.
        updateWatch(probeNow: true)
        onChange?()
    }

    // MARK: - Following the selected server

    /// True while the switch is off only because the selected server stopped
    /// answering; it turns back on when the server does.
    public var isSuspendedForUnreachableServer: Bool { watchdog.suspended }

    /// The server to watch: the selected plain server, while auto re-apply is
    /// on and the proxy is on or paused for it. Tunnels have their own rule.
    private var watchTarget: ProxyServer? {
        guard reapplyOnNetworkChange, let server, !tunnels.isTunnelProxy(server),
              desiredOn || watchdog.suspended else { return nil }
        return server
    }

    private func updateWatch(probeNow: Bool = false) {
        guard started else { return }
        let target = watchTarget
        if target != watchedServer {
            watchedServer = target
            confirmation?.cancel()
        }
        guard let target else {
            watchTimer?.cancel()
            watchTimer = nil
            // Nothing to follow any more, so nothing to come back for.
            if watchdog.suspended, !reapplyOnNetworkChange || server.map(tunnels.isTunnelProxy) ?? true {
                watchdog.reset()
            }
            return
        }
        let interval = watchdog.suspended ? suspendedWatchInterval : watchInterval
        if watchTimer == nil || watchTimerInterval != interval {
            watchTimer?.cancel()
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in
                guard let self, let watched = self.watchedServer else { return }
                self.reachability.probe(watched)
            }
            timer.resume()
            watchTimer = timer
            watchTimerInterval = interval
        }
        if probeNow { reachability.probe(target) }
    }

    private func probeFinished(_ probed: ProxyServer, _ status: ServerReachability.Status) {
        guard probed == watchedServer else { return }
        let reachable: Bool
        switch status {
        case .reachable: reachable = true
        case .unreachable: reachable = false
        case .unknown, .checking: return
        }
        switch watchdog.probed(reachable: reachable, proxyOn: desiredOn) {
        case .none:
            break
        case .confirmSoon:
            confirmation?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.watchedServer == probed else { return }
                self.reachability.probe(probed)
            }
            confirmation = work
            DispatchQueue.main.asyncAfter(deadline: .now() + confirmDelay, execute: work)
        case .suspend:
            // Automatic, like every unattended write: silent sudo or the
            // orange "waiting for you" state, never a password dialog.
            desiredOn = false
            _ = reconcile(trigger: .automatic)
            onChange?()
        case .resume:
            desiredOn = true
            _ = reconcile(trigger: .automatic)
            onChange?()
        }
        updateWatch()
    }

    // MARK: - Tunnels

    /// Tunnelmux's rule, as chosen: when the system proxy points at the bridge
    /// and every tunnel has given up, turn the proxy off so traffic goes direct
    /// instead of failing; when a tunnel comes back, turn it on again. Both
    /// writes are automatic, so they run only when sudo is silent — otherwise
    /// the usual orange "awaiting you" state shows.
    private func tunnelsChanged() {
        refreshServers()
        // The rule follows the one tunnel the system proxy points at; the
        // others' fortunes are irrelevant to it.
        if let config = tunnels.tunnel(forProxy: server), config.enabled {
            if desiredOn, isProxyActive, tunnels.hasGivenUp(config.id) {
                suspendedForTunnels = true
                desiredOn = false
                _ = reconcile(trigger: .automatic)
            } else if suspendedForTunnels, tunnels.state(of: config.id) == .connected {
                suspendedForTunnels = false
                desiredOn = true
                _ = reconcile(trigger: .automatic)
            }
        } else {
            suspendedForTunnels = false
        }
        updateWatch()
        onChange?()
    }

    /// True while the switch is off only because the tunnels are down.
    public var isSuspendedForTunnels: Bool { suspendedForTunnels }

    /// Move a tunnel's bridge off an occupied port. If the system proxy was
    /// pointed at the old address, point it at the new one (applied at once
    /// when on).
    public func moveTunnelProxyToFreePort(_ id: UUID) {
        let wasSelected = tunnels.tunnel(forProxy: server)?.id == id
        guard let port = tunnels.moveBridgeToFreePort(id) else { return }
        if wasSelected {
            select(ProxyServer(host: "127.0.0.1", port: Int(port)))
        } else {
            refresh()
        }
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
    /// gone away (a tunnel that has since dropped) must not be resurrected by
    /// writing to it.
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
