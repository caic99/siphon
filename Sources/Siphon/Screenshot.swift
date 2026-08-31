import AppKit
import SiphonCore

/// Renders the README screenshot from the app's own menu.
///
/// Not advertised in `--help`: it is a maintenance tool, not a feature. It runs
/// against an ephemeral defaults suite with discovery switched off, so the menu
/// shows example servers rather than whatever this Mac happens to be configured
/// with — the screenshot is the real UI, just not real hostnames.
enum Screenshot {
    private static let suite = "com.chucai.siphon.screenshot"

    static func capture(to path: String) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)

        let controller = ProxyController(defaults: defaults, discoversServers: false)
        // Seed before any refresh. An unset selection is adopted from whatever
        // this Mac is actually pointed at, which would put a real hostname in
        // the screenshot even with discovery off.
        // select() remembers each server; the last one stays checked. With the
        // switch off these only touch defaults, never the network.
        controller.select(ProxyServer(host: "proxy-2.example.com", port: 3128))
        controller.select(ProxyServer(host: "proxy-1.example.com", port: 3128))

        let delegate = AppDelegate(controller: controller)
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name(suite)))
        guard let menu = delegate.menu else { return }

        let size = menu.size
        let margin: CGFloat = 24
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return }
        let originTop = NSPoint(x: 160, y: 160)

        // A plain backdrop so the capture isn't whatever happens to be on screen.
        let backdrop = NSWindow(
            contentRect: NSRect(x: originTop.x - margin,
                                y: screen.frame.height - originTop.y - size.height - margin,
                                width: size.width + margin * 2,
                                height: size.height + margin * 2),
            styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(calibratedWhite: 0.93, alpha: 1)
        backdrop.level = .floating
        backdrop.orderFront(nil)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
            let rect = "\(Int(originTop.x - margin)),\(Int(originTop.y - margin)),"
                + "\(Int(size.width + margin * 2)),\(Int(size.height + margin * 2))"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", "-R", rect, path]
            try? process.run()
            process.waitUntilExit()
            DispatchQueue.main.async { menu.cancelTracking() }
        }

        menu.popUp(positioning: nil,
                   at: NSPoint(x: originTop.x, y: screen.frame.height - originTop.y),
                   in: nil)
        backdrop.orderOut(nil)
        defaults.removePersistentDomain(forName: suite)
        print("wrote \(path)")
    }
}
