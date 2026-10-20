import AppKit
import ApplicationServices
import SiphonCore

/// Renders the README screenshot from the app's own menu.
///
/// Not advertised in `--help`: it is a maintenance tool, not a feature. It runs
/// against an ephemeral defaults suite with discovery switched off, so the menu
/// shows example servers rather than whatever this Mac happens to be configured
/// with — the screenshot is the real UI, just not real hostnames.
///
/// The menu is opened by clicking the status item with a synthetic mouse event,
/// not with NSMenu.popUp: under the macOS 26 design, controls in an app that is
/// not active draw inactive (the switch is grey when on), and only a click on
/// the status item lets the app activate the way it does for a user. Posting
/// that click needs Accessibility access for the terminal running this.
enum Screenshot {
    private static let suite = "com.chucai.siphon.screenshot"
    private static let backdropColor = NSColor(calibratedWhite: 0.93, alpha: 1)
    private static let margin: CGFloat = 24

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
        // Example hosts do not resolve; show the dots as they look on a working
        // network rather than probing them and photographing two red ones.
        controller.reachability.seed(ProxyServer(host: "proxy-1.example.com", port: 3128), .reachable(latency: 0.012))
        controller.reachability.seed(ProxyServer(host: "proxy-2.example.com", port: 3128), .reachable(latency: 0.031))
        delegate.applicationDidFinishLaunching(Notification(name: Notification.Name(suite)))
        // The status item is placed by the system once the app is running its
        // event loop; before that its window has no meaningful frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            captureMenu(of: delegate, to: path, cleanup: { defaults.removePersistentDomain(forName: suite) })
        }
        NSApp.run()
    }

    private static func captureMenu(of delegate: AppDelegate, to path: String, cleanup: @escaping () -> Void) {
        guard let menu = delegate.menu, let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }),
              let item = ownStatusItemFrame(primaryHeight: primary.frame.height) else {
            FileHandle.standardError.write(Data("screenshot failed: cannot locate the status item (Accessibility access?)\n".utf8))
            exit(1)
        }
        let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: item.midX, y: item.midY)) } ?? primary
        let scale = screen.backingScaleFactor

        // A plain backdrop under the menu bar where the menu will drop, so the
        // capture isn't whatever happens to be on screen. The menu is left-
        // aligned to the item unless that would run off the screen; both cases
        // get slack, and the result is cropped to the menu afterwards.
        let size = menu.size
        let slack: CGFloat = 160
        var left = item.minX - 40 - margin
        if item.minX + size.width > screen.frame.maxX - 20 { left = screen.frame.maxX - size.width - slack }
        // Start just under the menu bar: a capture that includes the bar's
        // bottom edge has no backdrop along its top, and the crop below would
        // refuse it. The menu hangs from the bar, so nothing of it is lost.
        let top = screen.visibleFrame.maxY - 1
        let region = NSRect(x: left, y: top - size.height - 2 * margin - slack,
                            width: size.width + 2 * margin + slack, height: size.height + 2 * margin + slack)
        let backdrop = NSWindow(contentRect: region, styleMask: .borderless, backing: .buffered, defer: false)
        backdrop.backgroundColor = backdropColor
        backdrop.level = .floating
        backdrop.ignoresMouseEvents = true
        backdrop.orderFront(nil)

        // screencapture and CGEvent use top-left coordinates on the primary display.
        func flipped(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x, y: primary.frame.height - p.y) }
        let click = flipped(NSPoint(x: item.midX, y: item.midY))
        let topLeft = flipped(NSPoint(x: region.minX, y: region.maxY))
        let rect = "\(Int(topLeft.x)),\(Int(topLeft.y)),\(Int(region.width)),\(Int(region.height))"

        // Captures land in a scratch file; the target is only ever replaced by
        // a capture that passed, so a failed run cannot lose the current one.
        let scratch = NSTemporaryDirectory() + "siphon-screenshot-\(getpid()).png"
        FileHandle.standardError.write(Data("status item at \(item), click \(click), capture -R \(rect)\n".utf8))
        DispatchQueue.global().async {
            Thread.sleep(forTimeInterval: 0.5)
            post(.mouseMoved, at: click); Thread.sleep(forTimeInterval: 0.15)
            post(.leftMouseDown, at: click); Thread.sleep(forTimeInterval: 0.08)
            post(.leftMouseUp, at: click)
            var captured = false
            for attempt in 1...3 where !captured {
                Thread.sleep(forTimeInterval: 1.0 * Double(attempt))
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                process.arguments = ["-x", "-R", rect, scratch]
                try? process.run()
                process.waitUntilExit()
                captured = process.terminationStatus == 0 && cropToMenu(scratch, scale: scale)
                if captured {
                    try? FileManager.default.removeItem(atPath: path)
                    captured = (try? FileManager.default.moveItem(atPath: scratch, toPath: path)) != nil
                } else {
                    // Left in place for diagnosis; it is only ever the backdrop region.
                    FileHandle.standardError.write(Data("capture attempt \(attempt) did not show the menu on the backdrop (raw: \(scratch))\n".utf8))
                }
            }
            // Escape closes the menu; the app then exits from the main queue.
            postKey(53)
            DispatchQueue.main.async {
                backdrop.orderOut(nil)
                cleanup()
                if captured {
                    print("wrote \(path)")
                    exit(0)
                }
                FileHandle.standardError.write(Data("""
                    screenshot failed: nothing written to \(path)
                    The status item must open when clicked by a synthetic event, which needs \
                    Accessibility access for the terminal running this.

                    """.utf8))
                exit(1)
            }
        }
    }

    /// This process's status item, as the Accessibility API reports it, in
    /// Cocoa screen coordinates. The button's own window frame is not reliable
    /// here: measured against the AX rect it was a dozen points off, enough
    /// to click a neighbouring item.
    private static func ownStatusItemFrame(primaryHeight: CGFloat) -> NSRect? {
        let app = AXUIElementCreateApplication(getpid())
        var bar: AnyObject?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let barElement = bar else { return nil }
        var children: AnyObject?
        guard AXUIElementCopyAttributeValue(barElement as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement], let first = items.first else { return nil }
        var posValue: AnyObject?, sizeValue: AnyObject?
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(first, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(first, kAXSizeAttribute as CFString, &sizeValue) == .success,
              AXValueGetValue(posValue as! AXValue, .cgPoint, &pos), AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        // AX reports top-left coordinates on the primary display.
        return NSRect(x: pos.x, y: primaryHeight - pos.y - size.height, width: size.width, height: size.height)
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private static func postKey(_ code: CGKeyCode) {
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)?.post(tap: .cghidEventTap)
    }

    /// Crop the capture to the menu plus a margin of backdrop. Everything that
    /// is not the backdrop colour is "menu" (its shadow included); if nothing
    /// is, the menu never opened, and if it touches the capture's edge the
    /// backdrop was not behind all of it — either way the file is refused, so
    /// whatever was on screen behind can never become the README.
    private static func cropToMenu(_ path: String, scale: CGFloat) -> Bool {
        guard let image = NSImage(contentsOfFile: path),
              let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                ?? image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)),
              let want = backdropColor.usingColorSpace(.sRGB) else { return false }
        func isBackdrop(_ x: Int, _ y: Int) -> Bool {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return abs(c.redComponent - want.redComponent) <= 0.03 && abs(c.greenComponent - want.greenComponent) <= 0.03
                && abs(c.blueComponent - want.blueComponent) <= 0.03
        }
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where !isBackdrop(x, y) {
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else {
            FileHandle.standardError.write(Data("capture is \(rep.pixelsWide)x\(rep.pixelsHigh) of plain backdrop: the menu is not open\n".utf8))
            return false
        }
        // The menu hangs from the menu bar, so there is no backdrop above it;
        // that margin is painted in. The other three must be real.
        let pad = Int(margin * scale)
        guard minX - pad >= 0, maxX + pad < rep.pixelsWide, maxY + pad < rep.pixelsHigh else {
            FileHandle.standardError.write(Data("menu reaches the edge of the capture (\(minX),\(minY))-(\(maxX),\(maxY))\n".utf8))
            return false
        }
        let top = max(0, minY - pad)
        let crop = CGRect(x: minX - pad, y: top, width: maxX - minX + 2 * pad, height: maxY + pad - top)
        let canvas = CGSize(width: crop.width, height: CGFloat(maxY - minY + 2 * pad))
        guard let cg = rep.cgImage?.cropping(to: crop),
              let context = CGContext(data: nil, width: Int(canvas.width), height: Int(canvas.height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        context.setFillColor(want.cgColor)
        context.fill(CGRect(origin: .zero, size: canvas))
        // CG draws from the bottom; the cropped strip sits flush with the bottom.
        context.draw(cg, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        guard let out = context.makeImage(),
              let png = NSBitmapImageRep(cgImage: out).representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: URL(fileURLWithPath: path))) != nil
    }
}
