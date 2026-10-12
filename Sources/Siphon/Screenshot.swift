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
    private static let backdropColor = NSColor(calibratedWhite: 0.93, alpha: 1)

    /// The margin around the menu must show the backdrop. If it shows anything
    /// else, the backdrop was not covering the region and the capture contains
    /// whatever was on screen behind it -- which must never become the README.
    private static func showsBackdrop(_ path: String) -> Bool {
        guard let image = NSImage(contentsOfFile: path),
              let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else { return false }
        let want = backdropColor.usingColorSpace(.sRGB)!
        let points = [(3, 3), (rep.pixelsWide - 4, 3), (3, rep.pixelsHigh - 4), (rep.pixelsWide - 4, rep.pixelsHigh - 4)]
        for (x, y) in points {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            if abs(c.redComponent - want.redComponent) > 0.03 || abs(c.greenComponent - want.greenComponent) > 0.03
                || abs(c.blueComponent - want.blueComponent) > 0.03 { return false }
        }
        return true
    }

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
        // Two example tunnels, disabled so no ssh is launched for a picture;
        // they still show the row layout, state dot and port.
        for target in ["build-host.example.net", "lab-gateway.example.org"] {
            let t = controller.tunnels.add(target: target)
            controller.tunnels.setEnabled(t.id, false)
        }

        let delegate = AppDelegate(controller: controller)
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name(suite)))
        guard let menu = delegate.menu else { return }

        let size = menu.size
        let margin: CGFloat = 24
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else { return }
        // Whichever row the pointer rests on is drawn highlighted, so open the
        // menu on the half of the screen the pointer is not on. (Warping the
        // pointer away instead tripped a hot corner and cost the backdrop.)
        let mouse = NSEvent.mouseLocation
        let onLeftHalf = mouse.x < screen.frame.midX
        let originTop = NSPoint(x: onLeftHalf ? screen.frame.width - size.width - 200 : 160, y: 160)

        // A plain backdrop so the capture isn't whatever happens to be on screen.
        let backdrop = NSWindow(
            contentRect: NSRect(x: originTop.x - margin,
                                y: screen.frame.height - originTop.y - size.height - margin,
                                width: size.width + margin * 2,
                                height: size.height + margin * 2),
            styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = Self.backdropColor
        backdrop.level = .floating
        backdrop.orderFront(nil)

        // The first capture after a fresh build sometimes yields nothing while
        // the menu is still being drawn; so: remove any stale file first, give
        // the menu time to settle, retry with a longer delay, and only claim
        // success when screencapture exited 0 and the file exists.
        try? FileManager.default.removeItem(atPath: path)
        var captured = false
        DispatchQueue.global().async {
            let rect = "\(Int(originTop.x - margin)),\(Int(originTop.y - margin)),"
                + "\(Int(size.width + margin * 2)),\(Int(size.height + margin * 2))"
            for attempt in 1...3 where !captured {
                Thread.sleep(forTimeInterval: 0.8 * Double(attempt))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R", rect, path]
                try? process.run()
                process.waitUntilExit()
                captured = process.terminationStatus == 0 && FileManager.default.fileExists(atPath: path)
                    && Self.showsBackdrop(path)
                if !captured {
                    try? FileManager.default.removeItem(atPath: path)
                    FileHandle.standardError.write(Data("capture attempt \(attempt) failed or did not show the backdrop\n".utf8))
                }
            }
            DispatchQueue.main.async { menu.cancelTracking() }
        }

        menu.popUp(positioning: nil,
                   at: NSPoint(x: originTop.x, y: screen.frame.height - originTop.y),
                   in: nil)
        backdrop.orderOut(nil)
        defaults.removePersistentDomain(forName: suite)
        if captured {
            print("wrote \(path)")
        } else {
            FileHandle.standardError.write(Data("screenshot failed: nothing written to \(path)\n".utf8))
            exit(1)
        }
    }
}
