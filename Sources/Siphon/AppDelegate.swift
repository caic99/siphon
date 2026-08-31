import AppKit
import SiphonCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = ProxyController()

    private var statusItem: NSStatusItem!
    private var headerIconView: NSImageView!
    private var headerTitleLabel: NSTextField!
    private var headerSubtitleLabel: NSTextField!
    private var headerSwitch: NSSwitch!
    private var obstructionItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var customServerItem: NSMenuItem!
    private var reapplyItem: NSMenuItem!
    private var serverItems: [NSMenuItem] = []
    /// 54x24 down to 43x19 — proportionate to a menu row.
    private static let switchScale: CGFloat = 0.8
    private var menu: NSMenu!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller.onChange = { [weak self] in self?.refreshUI() }
        controller.onError = { [weak self] message in
            self?.showAlert("Couldn't change the proxy", message)
        }
        buildStatusItem()
        controller.start()
    }

    // MARK: - Menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        // Custom view so the header renders in solid label color instead of the
        // dimmed look AppKit forces on disabled items.
        let header = NSMenuItem()
        // Enabled on purpose: AppKit dims a disabled item's custom view, and
        // that is what drains the accent colour out of the switch. Nothing is
        // wired to the row itself — the switch inside it handles the click.
        header.isEnabled = true
        header.view = makeHeaderRow()
        menu.addItem(header)

        // Only shown when the live state and the switch disagree.
        obstructionItem = NSMenuItem(title: "", action: #selector(resolveObstruction),
                                     keyEquivalent: "")
        obstructionItem.target = self
        obstructionItem.image = NSImage(systemSymbolName: "exclamationmark.arrow.circlepath",
                                        accessibilityDescription: "Apply")
        menu.addItem(obstructionItem)
        menu.addItem(.separator())

        toggleItem = NSMenuItem(title: "Turn Proxy On", action: #selector(toggleProxy),
                                keyEquivalent: "p")
        toggleItem.target = self
        menu.addItem(toggleItem)
        menu.addItem(.separator())

        menu.addItem(Self.sectionHeader("Proxy Server"))
        customServerItem = NSMenuItem(title: "Custom…", action: #selector(addCustomServer),
                                      keyEquivalent: "")
        customServerItem.target = self
        menu.addItem(customServerItem)
        menu.addItem(.separator())

        reapplyItem = NSMenuItem(title: "Re-apply on Network Change",
                                 action: #selector(toggleReapply), keyEquivalent: "")
        reapplyItem.target = self
        reapplyItem.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                    accessibilityDescription: "Re-apply")
        reapplyItem.toolTip = "Re-apply the proxy to whichever service owns the default route "
            + "when it moves — a VPN connecting or dropping. Runs automatically only when "
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
        let width: CGFloat = 300, height: CGFloat = 36, margin: CGFloat = 14
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

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
        container.addSubview(toggle)

        let textX: CGFloat = 38
        let textWidth = toggle.frame.minX - 10 - textX

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: 18, width: textWidth, height: 16)
        container.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: textX, y: 4, width: textWidth, height: 13)
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

    @objc private func toggleReapply() {
        controller.reapplyOnNetworkChange.toggle()
    }

    @objc private func selectServer(_ sender: NSMenuItem) {
        guard let server = sender.representedObject as? ProxyServer else { return }
        controller.select(server)
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
            headerTitleLabel.stringValue = obstruction == nil ? "Proxy Off" : "Proxy Off — Not Applied"
            headerSubtitleLabel.stringValue = subtitleDetail()
        }
        headerSubtitleLabel.toolTip = controller.primary?.displayName
        headerSwitch.state = active ? .on : .off
        headerSwitch.isEnabled = controller.canToggle

        refreshObstructionItem()
        refreshToggleItem()
        refreshServerItems()
        reapplyItem.state = controller.reapplyOnNetworkChange ? .on : .off
    }

    /// The service line, or the reason the state is stuck — whichever the user
    /// needs more. The service always stays available in the tooltip.
    private func subtitleDetail() -> String {
        guard let primary = controller.primary else { return "" }
        switch controller.obstruction {
        case .awaitingUser:
            return "Needs your password · \(primary.name)"
        case .foreignProxy(let existing):
            let host = existing?.host ?? "Another proxy"
            return "\(host) was set outside Siphon"
        case .failed:
            return "Couldn't apply · \(primary.name)"
        case nil:
            return primary.displayName
        }
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

    /// Labelled from the live state, not the switch, so the row always describes
    /// what clicking it will actually do to the Mac.
    private func refreshToggleItem() {
        let active = controller.isProxyActive
        toggleItem.title = active ? "Turn Proxy Off" : "Turn Proxy On"
        toggleItem.image = NSImage(systemSymbolName: active ? "stop.circle" : "play.circle",
                                   accessibilityDescription: active ? "Turn off" : "Turn on")
        toggleItem.isEnabled = controller.canToggle
    }

    private func refreshServerItems() {
        for item in serverItems { menu.removeItem(item) }
        serverItems = []

        guard let insertionIndex = menu.items.firstIndex(of: customServerItem) else { return }
        for (offset, server) in controller.knownServers.enumerated() {
            let item = NSMenuItem(title: server.display, action: #selector(selectServer(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = server
            item.state = server == controller.server ? .on : .off
            menu.insertItem(item, at: insertionIndex + offset)
            serverItems.append(item)
        }
    }
}
