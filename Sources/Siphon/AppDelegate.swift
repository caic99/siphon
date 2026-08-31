import AppKit
import SiphonCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = ProxyController()

    private var statusItem: NSStatusItem!
    private var headerIconView: NSImageView!
    private var headerTitleLabel: NSTextField!
    private var headerSubtitleLabel: NSTextField!
    private var obstructionItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var customServerItem: NSMenuItem!
    private var reapplyItem: NSMenuItem!
    private var serverItems: [NSMenuItem] = []
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
        header.isEnabled = false
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
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 36))

        let icon = NSImageView(frame: NSRect(x: 14, y: 9, width: 18, height: 18))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        icon.contentTintColor = .labelColor
        container.addSubview(icon)

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: 38, y: 18, width: 250, height: 16)
        container.addSubview(title)

        let subtitle = NSTextField(labelWithString: "")
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.frame = NSRect(x: 38, y: 4, width: 250, height: 13)
        container.addSubview(subtitle)

        headerIconView = icon
        headerTitleLabel = title
        headerSubtitleLabel = subtitle
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
            let server = controller.activeServer.map { " — \($0.display)" } ?? ""
            headerTitleLabel.stringValue = "Proxy On\(server)"
            headerSubtitleLabel.stringValue = subtitleDetail()
        } else {
            headerTitleLabel.stringValue = obstruction == nil ? "Proxy Off" : "Proxy Off — Not Applied"
            headerSubtitleLabel.stringValue = subtitleDetail()
        }
        headerSubtitleLabel.toolTip = controller.primary?.displayName

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
