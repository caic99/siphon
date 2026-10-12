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
    private var customServerItem: NSMenuItem!
    private var copyExportsItem: NSMenuItem!
    private var tunnelsHeaderItem: NSMenuItem!
    private var addTunnelItem: NSMenuItem!
    private var tunnelItems: [NSMenuItem] = []
    private var reapplyItem: NSMenuItem!
    private var serverItems: [NSMenuItem] = []
    /// 54x24 down to 43x19 — proportionate to a menu row.
    private static let switchScale: CGFloat = 0.8
    /// Internal so the screenshot harness can pop up the real menu.
    var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onChange = { [weak self] in self?.refreshUI() }
        controller.onError = { [weak self] message in
            self?.showAlert("Couldn't change the proxy", message)
        }
        buildStatusItem()
        controller.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
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

        menu.addItem(Self.sectionHeader("Proxy Server"))
        customServerItem = NSMenuItem(title: "Custom…", action: #selector(addCustomServer),
                                      keyEquivalent: "")
        customServerItem.target = self
        menu.addItem(customServerItem)
        menu.addItem(.separator())

        // SSH tunnels: each row is a submenu; the bridge address rides in the
        // section header so it is visible without opening anything.
        tunnelsHeaderItem = Self.sectionHeader("SSH Tunnels")
        menu.addItem(tunnelsHeaderItem)
        addTunnelItem = NSMenuItem(title: "Add SSH Tunnel…", action: #selector(addTunnel),
                                   keyEquivalent: "")
        addTunnelItem.target = self
        addTunnelItem.toolTip = "ssh -N -D to a host from your ssh config (keys or agent; no prompts). "
            + "Connected tunnels are load-balanced behind one local HTTP proxy, which then "
            + "appears under Proxy Server."
        menu.addItem(addTunnelItem)
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
            + "Runs automatically only when "
            + "passwordless sudo is available, so a password dialog never appears unprompted."
        menu.addItem(reapplyItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Siphon",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
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

        // NSSwitch ignores controlSize — it is a fixed 54x24 at every setting,
        // which is chunky next to 13pt menu text. Scaling the view's unit square
        // shrinks the frame while the switch keeps drawing into its full 54x24
        // bounds, so the artwork stays vector-sharp rather than being a
        // resampled bitmap.
        let natural = toggle.frame.size
        toggle.scaleUnitSquare(to: NSSize(width: Self.switchScale, height: Self.switchScale))
        let switchSize = NSSize(width: (natural.width * Self.switchScale).rounded(),
                                height: (natural.height * Self.switchScale).rounded())
        toggle.setFrameSize(switchSize)
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

    func menuWillOpen(_ menu: NSMenu) {
        controller.refresh()
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
        guard let server = controller.activeServer ?? controller.server else { return }
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
        controller.tunnels.setEnabled(id, !config.enabled)
    }

    @objc private func retryTunnel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller.tunnels.retry(id)
    }

    @objc private func removeTunnel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        controller.tunnels.remove(id)
    }

    @objc private func useTunnelsAsProxy() {
        controller.select(ProxyServer(host: "127.0.0.1", port: Int(controller.tunnels.httpPort)))
    }

    @objc private func addCustomServer() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Proxy Server"
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
        copyExportsItem.isEnabled = (controller.activeServer ?? controller.server) != nil
        refreshObstructionItem()
        refreshServerItems()
        refreshTunnelItems()
        reapplyItem.state = controller.reapplyOnNetworkChange ? .on : .off
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
            return controller.isSuspendedForTunnels ? "Paused · tunnels down" : primary.name
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
        tunnelsHeaderItem.title = tunnels.enabledCount > 0
            ? "SSH Tunnels · http://127.0.0.1:\(tunnels.httpPort)"
            : "SSH Tunnels"
        tunnelsHeaderItem.toolTip = tunnels.bridgeError.map { "Local proxy not listening: \($0)" }

        guard let insertionIndex = menu.items.firstIndex(of: addTunnelItem) else { return }
        for (offset, config) in tunnels.configs.enumerated() {
            let state = tunnels.state(of: config.id)
            let item = NSMenuItem(title: config.target, action: nil, keyEquivalent: "")
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
                (color, detail) = (.systemRed, "Gave up: \(reason)")
            case .idle:
                (color, detail) = (config.enabled ? .systemYellow : .tertiaryLabelColor,
                                   config.enabled ? "Starting…" : "Disconnected")
            }
            item.image = Self.stateDot(color)
            item.toolTip = "\(detail)\nSOCKS5 on 127.0.0.1:\(config.socksPort)"

            let sub = NSMenu()
            let toggle = NSMenuItem(title: config.enabled ? "Disconnect" : "Connect",
                                    action: #selector(toggleTunnel(_:)), keyEquivalent: "")
            toggle.target = self; toggle.representedObject = config.id
            sub.addItem(toggle)
            if case .gaveUp = state {
                let retry = NSMenuItem(title: "Retry Now", action: #selector(retryTunnel(_:)), keyEquivalent: "")
                retry.target = self; retry.representedObject = config.id
                sub.addItem(retry)
            }
            let status = NSMenuItem(title: detail, action: nil, keyEquivalent: "")
            status.isEnabled = false
            sub.addItem(status)
            sub.addItem(.separator())
            let use = NSMenuItem(title: "Use Tunnels as System Proxy", action: #selector(useTunnelsAsProxy),
                                 keyEquivalent: "")
            use.target = self
            use.state = tunnels.isTunnelProxy(controller.server) ? .on : .off
            sub.addItem(use)
            let remove = NSMenuItem(title: "Remove", action: #selector(removeTunnel(_:)), keyEquivalent: "")
            remove.target = self; remove.representedObject = config.id
            sub.addItem(remove)
            item.submenu = sub

            menu.insertItem(item, at: insertionIndex + offset)
            tunnelItems.append(item)
        }
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

        guard let insertionIndex = menu.items.firstIndex(of: customServerItem) else { return }
        let servers = controller.knownServers
        let labels = ServerLabels.labels(for: servers)
        for (offset, server) in servers.enumerated() {
            var label = labels[offset]
            if controller.tunnels.isTunnelProxy(server) {
                let n = controller.tunnels.connectedCount
                label = "SSH Tunnels · \(server.display)" + (n == 0 ? "" : "  (\(n) up)")
            }
            let item = NSMenuItem(title: label, action: #selector(selectServer(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = server
            item.state = server == controller.server ? .on : .off
            // The row is shortened for width; the tooltip keeps the whole name.
            item.toolTip = label == server.display ? nil : server.display
            menu.insertItem(item, at: insertionIndex + offset)
            serverItems.append(item)
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
