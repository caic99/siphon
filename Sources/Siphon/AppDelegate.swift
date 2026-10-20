import AppKit
import SiphonCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller: ProxyController

    init(controller: ProxyController = ProxyController()) {
        self.controller = controller
        super.init()
    }

    private var statusItem: NSStatusItem!
    private var headerIconView: NSImageView!
    private var headerTitleLabel: NSTextField!
    private var headerSubtitleLabel: NSTextField!
    private var headerSwitch: NSSwitch!
    private var headerItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var obstructionItem: NSMenuItem!
    private var serverHeaderItem: NSMenuItem!
    private var customServerItem: NSMenuItem!
    private var copyExportsItem: NSMenuItem!
    private var addTunnelItem: NSMenuItem!
    private var removeItem: NSMenuItem!
    private var tunnelItems: [NSMenuItem] = []
    private var reapplyItem: NSMenuItem!
    private var serverItems: [NSMenuItem] = []
    private var reachability: ServerReachability { controller.reachability }
    /// Internal so the screenshot harness can pop up the real menu.
    var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onChange = { [weak self] in self?.refreshUI() }
        controller.onReachabilityChange = { [weak self] in self?.refreshServerDots() }
        controller.onError = { [weak self] message in
            self?.showAlert("Couldn't change the proxy", message)
        }
        installSignalHandlers()
        buildStatusItem()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    /// applicationWillTerminate runs for Quit, not for SIGTERM/SIGINT/SIGHUP
    /// (pkill, logout, a terminal closing). Catch those too, so ssh children
    /// never outlive the app on any exit short of a crash — and a crash's
    /// leftovers are reaped at the next launch by ChildRegistry.
    private var signalSources: [DispatchSourceSignal] = []

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller.shutdown()
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Custom view so the header renders in solid label color instead of the
        // dimmed look AppKit forces on disabled items.
        // The header *is* the toggle: the switch, a click anywhere else on the
        // row, and ⌘P all do the same thing. The action and key equivalent live
        // on the item so the keyboard path works; the custom view forwards row
        // clicks to the same selector, since AppKit does not fire an item's
        // action for clicks inside its view.
        // No key equivalent: AppKit does not honour one on an item with a custom
        // view (measured — the delegate hook and the view's own
        // performKeyEquivalent are not consulted either), and the header needs
        // a custom view for the switch.
        headerItem = NSMenuItem(title: "", action: #selector(toggleProxy), keyEquivalent: "")
        headerItem.target = self
        headerItem.view = makeHeaderRow()
        menu.addItem(headerItem)

        // Only shown when the live state and the switch disagree.
        obstructionItem = NSMenuItem(title: "", action: #selector(resolveObstruction),
                                     keyEquivalent: "")
        obstructionItem.target = self
        obstructionItem.image = NSImage(systemSymbolName: "exclamationmark.arrow.circlepath",
                                        accessibilityDescription: "Apply")
        menu.addItem(obstructionItem)
        menu.addItem(.separator())

        // The header toggles too, but a menu item with a custom view cannot
        // carry a key equivalent, so ⌘S needs a plain row to live on.
        toggleItem = NSMenuItem(title: "Turn Proxy On", action: #selector(toggleProxy),
                                keyEquivalent: "s")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        serverHeaderItem = Self.sectionHeader("Proxy Server")
        menu.addItem(serverHeaderItem)
        // Server and tunnel rows are inserted after the header on refresh.
        menu.addItem(.separator())

        copyExportsItem = NSMenuItem(title: "Copy Shell Exports",
                                     action: #selector(copyExports), keyEquivalent: "c")
        copyExportsItem.target = self
        copyExportsItem.image = NSImage(systemSymbolName: "doc.on.doc",
                                        accessibilityDescription: "Copy")
        copyExportsItem.toolTip = "Copy HTTP_PROXY / HTTPS_PROXY exports for a terminal. "
            + "System proxy settings don't reach curl, git or pip — they read these variables."
        menu.addItem(copyExportsItem)

        reapplyItem = NSMenuItem(title: "Auto Re-apply",
                                 action: #selector(toggleReapply), keyEquivalent: "r")
        reapplyItem.target = self
        reapplyItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                    accessibilityDescription: "Re-apply")
        reapplyItem.toolTip = "Re-apply the proxy to whichever service owns the default route "
            + "when it moves — a cable going in, Wi-Fi taking over, a tunnel coming up. "
            + "Runs automatically only when passwordless sudo is available, so a password "
            + "dialog never appears unprompted."
        menu.addItem(reapplyItem)
        menu.addItem(.separator())

        // Editing the list lives in its own segment: the list above stays
        // pure content.
        customServerItem = NSMenuItem(title: "Add Proxy Server…", action: #selector(addCustomServer),
                                      keyEquivalent: "")
        customServerItem.target = self
        customServerItem.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "Proxy server")
        menu.addItem(customServerItem)
        addTunnelItem = NSMenuItem(title: "Add SSH Tunnel…", action: #selector(addTunnel),
                                   keyEquivalent: "")
        addTunnelItem.target = self
        addTunnelItem.image = NSImage(systemSymbolName: "terminal", accessibilityDescription: "SSH")
        addTunnelItem.toolTip = "ssh -N -D to a host from your ssh config (keys or agent; no prompts). "
            + "Each tunnel is its own local HTTP proxy: click a tunnel to point the system at it, "
            + "hold ⌥ to connect or disconnect it."
        menu.addItem(addTunnelItem)
        // Added servers and tunnels; discovered servers come from the system
        // and are not ours to remove.
        removeItem = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
        removeItem.image = NSImage(systemSymbolName: "minus.circle", accessibilityDescription: "Remove")
        removeItem.submenu = NSMenu()
        menu.addItem(removeItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Siphon",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        quit.image = NSImage(systemSymbolName: "xmark.square", accessibilityDescription: "Quit")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func makeHeaderRow() -> NSView {
        // 225pt is what the server rows impose anyway, so the header costs
        // nothing at this width — and the service name fits without clipping.
        let width: CGFloat = 225, height: CGFloat = 36, margin: CGFloat = 14
        let container = ClickableView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        // The menu is as wide as its widest row, which may be wider than this
        // view's nominal 225pt (a long tunnel name, say). Stretch with the menu
        // so the switch, anchored by its right margin below, stays flush right.
        container.autoresizingMask = [.width]
        // Clicks that land on the switch never reach here — it consumes them —
        // so this only covers the rest of the row.
        container.onClick = { [weak self] in self?.toggleProxy() }

        let icon = NSImageView(frame: NSRect(x: margin, y: 9, width: 18, height: 18))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .labelColor
        container.addSubview(icon)

        // The switch is placed first and measured, not guessed at: its size
        // varies by macOS version, and the labels are then given exactly the
        // room that remains so they truncate instead of running underneath it.
        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = #selector(headerSwitchFlipped(_:))
        toggle.setAccessibilityLabel("Proxy")
        toggle.sizeToFit()

        // Left at its native size and drawing. Scaling it (scaleUnitSquare, as
        // before) breaks the Liquid Glass switch: its knob is a glass lens
        // drawn outside the scaled bounds, which showed as a stray ring and a
        // knob drawn off the track.
        let switchSize = toggle.frame.size
        toggle.setFrameOrigin(NSPoint(x: width - switchSize.width - margin,
                                      y: ((height - switchSize.height) / 2).rounded()))
        toggle.autoresizingMask = [.minXMargin]
        container.addSubview(toggle)

        let textX: CGFloat = 38
        let textWidth = toggle.frame.minX - 10 - textX

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: 18, width: textWidth, height: 16)
        title.autoresizingMask = [.width]
        container.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: textX, y: 4, width: textWidth, height: 13)
        subtitle.autoresizingMask = [.width]
        container.addSubview(subtitle)

        headerIconView = icon
        headerTitleLabel = title
        headerSubtitleLabel = subtitle
        headerSwitch = toggle
        return container
    }

    private static func sectionHeader(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    /// Under the macOS 26 design, controls in an app that is not active draw
    /// inactive: the header switch stays grey when on (measured in the real
    /// menu; the same switch is blue once the app is active). A status item
    /// menu never activates its app by itself, so activation is taken here and
    /// handed back to whatever was in front when the menu closes. The older
    /// call is deliberate: measured on macOS 27, `activate()` is not granted
    /// from a status item click, while `activate(ignoringOtherApps:)` is.
    private var appToReactivate: NSRunningApplication?

    func menuWillOpen(_ menu: NSMenu) {
        controller.refresh()
        if #available(macOS 26.0, *), !NSApp.isActive {
            appToReactivate = NSWorkspace.shared.frontmostApplication
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard let previous = appToReactivate else { return }
        appToReactivate = nil
        previous.activate()
    }

    // MARK: - Actions

    @objc private func toggleProxy() {
        controller.toggle()
    }

    /// The switch shows live state, so it is not the source of truth — flipping
    /// it asks for a change, and refreshUI snaps it back to whatever the Mac
    /// actually ends up reporting.
    @objc private func headerSwitchFlipped(_ sender: NSSwitch) {
        controller.setOn(sender.state == .on)
    }

    @objc private func resolveObstruction() {
        controller.resolveObstruction()
    }

    /// Exports for the server actually in force, falling back to the selection
    /// when the proxy is off — a terminal is often proxied while the system is
    /// not.
    @objc private func copyExports() {
        guard let server = controller.exportServer else { return }
        let commands = ShellExports.commands(for: server)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commands, forType: .string)
    }

    @objc private func toggleReapply() {
        controller.reapplyOnNetworkChange.toggle()
    }

    @objc private func selectServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? ProxyServer else { return }
        controller.select(server)
    }

    @objc private func addTunnel() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "SSH Tunnel"
        alert.informativeText = "A host as you would type it after ssh — an alias from ~/.ssh/config "
            + "or user@host. It must sign in without a prompt (keys or agent). Siphon runs "
            + "ssh -N -D: no command executes on the remote side."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "user@host"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let target = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty, !target.contains(" "), !target.hasPrefix("-") else {
            showAlert("That isn't an SSH destination", "Use a config alias or user@host, with no spaces.")
            return
        }
        controller.tunnels.add(target: target)
    }

    @objc private func toggleTunnel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let config = controller.tunnels.configs.first(where: { $0.id == id }) else { return }
        if config.enabled {
            controller.tunnels.setEnabled(id, false)
        } else {
            controller.tunnels.setEnabled(id, true)
            controller.tunnels.connect(id)
        }
    }

    @objc private func retryTunnel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller.tunnels.retry(id)
    }

    @objc private func forgetServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? ProxyServer else { return }
        controller.forgetServer(server)
    }

    @objc private func removeTunnel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller.tunnels.remove(id)
    }

    /// Point the system proxy at this tunnel. Using a tunnel implies wanting
    /// it up, so a disconnected or given-up one is started too. A port that
    /// something else holds is dealt with here, when it actually matters,
    /// rather than moved behind the user's back.
    @objc private func useTunnelAsProxy(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let config = controller.tunnels.configs.first(where: { $0.id == id }) else { return }
        let tunnels = controller.tunnels
        if let error = tunnels.bridgeError(for: id) {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Port \(config.httpPort) is in use"
            alert.informativeText = "This tunnel's proxy can't listen on port \(config.httpPort) (\(error))"
                + (tunnels.bridgePortOwner(for: id).map { " — it's held by \($0)" } ?? "")
                + ". Move it to the next free port? Exports and anything else pointing at the "
                + "old port will need updating."
            alert.addButton(withTitle: "Move Port")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            controller.moveTunnelProxyToFreePort(id)
        }
        if !config.enabled { tunnels.setEnabled(id, true) }
        tunnels.connect(id)
        controller.select(tunnels.proxyAddress(for: tunnels.configs.first { $0.id == id } ?? config))
    }

    @objc private func addCustomServer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Add Proxy Server"
        alert.informativeText = "Host and port, for example proxy.example.com:"
            + "\(ProxyServer.defaultPort). The port may be omitted."
        alert.addButton(withTitle: "Use")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "proxy.example.com:\(ProxyServer.defaultPort)"
        field.stringValue = controller.server?.display ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let server = ProxyServer.parse(field.stringValue) else {
            showAlert("That isn't a usable proxy server",
                      "Enter a hostname or IP address, optionally followed by \":port\" — "
                      + "for example proxy.example.com:\(ProxyServer.defaultPort).")
            return
        }
        controller.select(server)
    }

    private func showAlert(_ message: String, _ informative: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = informative
        alert.runModal()
    }

    // MARK: - UI state

    /// Prefers a newer symbol, degrading gracefully where the OS lacks it
    /// (NSImage returns nil for unknown names) so the 13.0 target holds.
    private static func symbolImage(_ preferred: String, fallback: String,
                                    description: String) -> NSImage? {
        NSImage(systemSymbolName: preferred, accessibilityDescription: description)
            ?? NSImage(systemSymbolName: fallback, accessibilityDescription: description)
    }

    private static func icon(active: Bool, description: String) -> NSImage? {
        active
            ? symbolImage("arrow.triangle.turn.up.right.diamond.fill",
                          fallback: "network", description: description)
            : symbolImage("arrow.triangle.turn.up.right.diamond",
                          fallback: "network", description: description)
    }

    private func refreshUI() {
        let active = controller.isProxyActive
        let obstruction = controller.obstruction
        let description = active ? "Siphon: proxy on" : "Siphon: proxy off"

        statusItem.button?.image = Self.icon(active: active, description: description)
        // Orange is the only signal that the switch and reality disagree; the
        // glyph itself always reports what the system is actually doing.
        statusItem.button?.contentTintColor = obstruction == nil ? nil : .systemOrange
        statusItem.button?.toolTip = description

        headerIconView.image = Self.icon(active: active, description: description)
        headerIconView.contentTintColor = obstruction == nil ? .labelColor : .systemOrange

        if controller.primary == nil {
            headerTitleLabel.stringValue = "No Network"
            headerSubtitleLabel.stringValue = "Nothing owns the default route"
        } else if active {
            headerTitleLabel.stringValue = "Proxy On"
            headerSubtitleLabel.stringValue = subtitleDetail()
        } else {
            headerTitleLabel.stringValue = "Proxy Off"
            headerSubtitleLabel.stringValue = subtitleDetail()
        }
        headerSubtitleLabel.toolTip = controller.primary?.displayName
        // NSSwitch animates its own knob when clicked, and animates programmatic
        // changes only through the animator proxy. Re-assigning a state it
        // already holds cancels the in-flight animation, which is what made
        // clicking it snap.
        let desired: NSControl.StateValue = active ? .on : .off
        if headerSwitch.state != desired { headerSwitch.animator().state = desired }
        headerSwitch.isEnabled = controller.canToggle

        headerItem.isEnabled = controller.canToggle
        refreshToggleItem()
        copyExportsItem.isEnabled = controller.exportServer != nil
        refreshObstructionItem()
        refreshServerItems()
        refreshTunnelItems()
        reapplyItem.state = controller.reapplyOnNetworkChange ? .on : .off
        keepImagesVisible(in: menu)
    }

    /// macOS 27 hides menu item images by default in apps linked on the macOS
    /// 26 SDK or later. Siphon's images are meaning, not decoration: the state
    /// dots are the only indication of a tunnel's or server's state. So every
    /// image is explicitly kept.
    private func keepImagesVisible(in menu: NSMenu) {
        guard #available(macOS 27.0, *) else { return }
        for item in menu.items {
            if item.image != nil { item.preferredImageVisibility = .visible }
            if let submenu = item.submenu { keepImagesVisible(in: submenu) }
        }
    }

    /// The service line, or the reason the state is stuck — whichever the user
    /// needs more. The service always stays available in the tooltip.
    private func subtitleDetail() -> String {
        guard let primary = controller.primary else { return "" }
        // Kept short: this line sets the menu's width, and the full service
        // name and interface stay in the tooltip.
        switch controller.obstruction {
        case .awaitingUser:
            return "Needs your password"
        case .foreignProxy:
            return "Set outside Siphon"
        case .failed:
            return "Couldn't apply"
        case nil:
            if controller.isSuspendedForTunnels { return "Paused · tunnel down" }
            if controller.isSuspendedForUnreachableServer { return "Paused · proxy unreachable" }
            if let config = controller.tunnels.tunnel(forProxy: controller.server),
               controller.tunnels.state(of: config.id) == .dormant {
                return "\(primary.name) · tunnel asleep, wakes on use"
            }
            return primary.name
        }
    }

    /// Labelled from the live state, not the switch, so the row always says what
    /// clicking it will actually do to the Mac.
    private func refreshToggleItem() {
        let active = controller.isProxyActive
        toggleItem.title = active ? "Turn Proxy Off" : "Turn Proxy On"
        toggleItem.image = NSImage(systemSymbolName: active ? "stop.circle" : "play.circle",
                                   accessibilityDescription: active ? "Turn off" : "Turn on")
        toggleItem.isEnabled = controller.canToggle
    }

    /// "user@long.host.name" -> "long". The full target stays in tooltips.
    private static func shortTarget(_ target: String) -> String {
        let host = target.split(separator: "@").last.map(String.init) ?? target
        let first = host.split(separator: ".").first.map(String.init) ?? host
        return first.isEmpty ? host : first
    }

    private static func stateDot(_ color: NSColor) -> NSImage? {
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .regular)
                .applying(.init(paletteColors: [color])))
        image?.isTemplate = false
        return image
    }

    private func refreshTunnelItems() {
        let tunnels = controller.tunnels
        for item in tunnelItems { menu.removeItem(item) }
        tunnelItems = []
        // Tunnel rows follow the server rows.
        guard let header = menu.items.firstIndex(of: serverHeaderItem) else { return }
        let insertionIndex = header + 1 + serverItems.count
        let selectedID = tunnels.tunnel(forProxy: controller.server)?.id
        var offset = 0
        for config in tunnels.configs {
            let state = tunnels.state(of: config.id)
            let (color, detail): (NSColor, String)
            switch state {
            case .connected:
                let since = tunnels.connectedSince(config.id).map { " for \(Self.format(Date().timeIntervalSince($0)))" } ?? ""
                (color, detail) = (.systemGreen, "Connected\(since)")
            case .connecting:
                (color, detail) = (.systemYellow, "Connecting…")
            case .reconnecting(let reason, let attempt):
                (color, detail) = (.systemOrange, "Reconnecting (\(attempt)/3): \(reason)")
            case .gaveUp(let reason):
                var text = "Gave up: \(reason) — click to retry"
                if reason.contains("SOCKS port"), let owner = tunnels.socksPortOwner(for: config.id) {
                    text += " (held by \(owner))"
                }
                (color, detail) = (.systemRed, text)
            case .dormant:
                (color, detail) = (.systemGray, "Ready — connects on first use, sleeps after 10 min idle")
            case .idle:
                (color, detail) = (config.enabled ? .systemYellow : .tertiaryLabelColor,
                                   config.enabled ? "Starting…" : "Disconnected — click to connect and use")
            }
            let bridgeError = tunnels.bridgeError(for: config.id)

            // The row is the proxy: click selects it, ✓ marks the selected one.
            let item = NSMenuItem(title: config.target, action: #selector(useTunnelAsProxy(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = config.id
            item.state = selectedID == config.id ? .on : .off
            item.image = Self.stateDot(bridgeError == nil ? color : .systemRed)
            item.toolTip = "\(detail)\nHTTP :\(config.httpPort) · SOCKS5 :\(config.socksPort)"
                + (bridgeError.map { "\nProxy not listening: \($0)"
                    + (tunnels.bridgePortOwner(for: config.id).map { " — port held by \($0)" } ?? "") } ?? "")
            menu.insertItem(item, at: insertionIndex + offset); offset += 1
            tunnelItems.append(item)

            // ⌥ swaps the row for connect/disconnect.
            let alt = NSMenuItem(title: (config.enabled ? "Disconnect " : "Connect ") + Self.shortTarget(config.target),
                                 action: #selector(toggleTunnel(_:)), keyEquivalent: "")
            alt.target = self
            alt.representedObject = config.id
            alt.isAlternate = true
            alt.keyEquivalentModifierMask = [.option]
            alt.image = item.image
            menu.insertItem(alt, at: insertionIndex + offset); offset += 1
            tunnelItems.append(alt)
        }

        // Removal lives in one submenu so a stray click can't do it.
        let removeMenu = removeItem.submenu!
        removeMenu.removeAllItems()
        let added = controller.addedServers
        let labels = ServerLabels.labels(for: added)
        for (i, server) in added.enumerated() {
            let item = NSMenuItem(title: labels[i], action: #selector(forgetServer(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = server
            removeMenu.addItem(item)
        }
        if !added.isEmpty, !tunnels.configs.isEmpty { removeMenu.addItem(.separator()) }
        for config in tunnels.configs {
            let item = NSMenuItem(title: config.target, action: #selector(removeTunnel(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = config.id
            removeMenu.addItem(item)
        }
        removeItem.isHidden = added.isEmpty && tunnels.configs.isEmpty
    }

    private static func format(_ interval: TimeInterval) -> String {
        let m = Int(interval) / 60
        if m < 1 { return "<1m" }
        if m < 60 { return "\(m)m" }
        return "\(m / 60)h \(m % 60)m"
    }

    private func refreshObstructionItem() {
        switch controller.obstruction {
        case .awaitingUser(.enable(let server)):
            obstructionItem.isHidden = false
            obstructionItem.title = "Apply \(server.display) Now"
        case .awaitingUser(.disable):
            obstructionItem.isHidden = false
            obstructionItem.title = "Turn the Proxy Off Now"
        case .foreignProxy:
            obstructionItem.isHidden = false
            obstructionItem.title = controller.server.map { "Replace with \($0.display)" }
                ?? "Replace"
        case .failed(.enable(let server), _):
            obstructionItem.isHidden = false
            obstructionItem.title = "Retry \(server.display)"
        case .failed(.disable, _):
            obstructionItem.isHidden = false
            obstructionItem.title = "Retry Turning the Proxy Off"
        case nil:
            obstructionItem.isHidden = true
        }
    }

    private func refreshServerItems() {
        for item in serverItems { menu.removeItem(item) }
        serverItems = []

        guard let header = menu.items.firstIndex(of: serverHeaderItem) else { return }
        let insertionIndex = header + 1
        let servers = controller.knownServers
        let labels = ServerLabels.labels(for: servers)
        for (offset, server) in servers.enumerated() {
            let item = NSMenuItem(title: labels[offset], action: #selector(selectServer(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = server
            item.state = server == controller.server ? .on : .off
            menu.insertItem(item, at: insertionIndex + offset)
            serverItems.append(item)
        }
        refreshServerDots()
        // Probes only on these refreshes (menu opening, a change), rate-limited
        // in the prober itself; the answer lands through reachability.onChange.
        reachability.check(servers)
    }

    /// The server rows' dots match the tunnel rows': green when the port
    /// accepts, red when it does not, grey until known. Updated in place so a
    /// probe answering while the menu is open does not rebuild it.
    private func refreshServerDots() {
        for item in serverItems {
            guard let server = item.representedObject as? ProxyServer else { continue }
            let (color, detail): (NSColor, String)
            switch reachability.status(of: server) {
            case .reachable(let latency):
                (color, detail) = (.systemGreen, "Reachable · \(Int((latency * 1000).rounded())) ms")
            case .unreachable(let reason):
                (color, detail) = (.systemRed, "Unreachable: \(reason)")
            case .checking:
                (color, detail) = (.systemGray, "Checking…")
            case .unknown:
                (color, detail) = (.systemGray, "Not checked yet")
            }
            item.image = Self.stateDot(color)
            // The row is shortened for width; the tooltip keeps the whole address.
            item.toolTip = "\(detail)\n\(server.display)"
        }
    }
}

/// A menu-row view that reports plain clicks. Menu items with custom views do
/// not fire their own action, so the row would otherwise be inert everywhere
/// except on the switch.
private final class ClickableView: NSView {
    var onClick: (() -> Void)?

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
}
