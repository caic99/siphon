import Foundation
import SiphonCore

/// Headless launch arguments, so Siphon is as scriptable as the shell script it
/// replaces. These run without an NSApplication and exit with the result.
enum Command {
    static let usage = """
    Siphon — menu bar proxy switch

      --on        route the current network service through the selected proxy
      --off       turn the proxy off, here and on any service Siphon proxied
      --toggle    flip whichever way the current service is set
      --probe     report what Siphon sees, change nothing
      --help      this message

    With no arguments Siphon runs as a menu bar app.
    """

    /// Returns an exit code, or nil when there is no headless work to do and the
    /// menu bar app should start.
    static func run(_ arguments: [String]) -> Int32? {
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return 0
        }
        if arguments.contains("--probe") {
            Probe.run()
            return 0
        }

        let controller = ProxyController()
        var failure: String?
        controller.onError = { failure = $0 }
        controller.refresh()

        if arguments.contains("--on") {
            controller.setOn(true)
        } else if arguments.contains("--off") {
            controller.setOn(false)
        } else if arguments.contains("--toggle") {
            controller.toggle()
        } else {
            return nil
        }

        controller.refresh()
        if let failure {
            FileHandle.standardError.write(Data((failure + "\n").utf8))
            return 1
        }
        guard let primary = controller.primary else {
            FileHandle.standardError.write(Data("no default route\n".utf8))
            return 1
        }

        let state = controller.isProxyActive
            ? "proxy ON — " + (controller.activeServer?.display ?? "unknown")
            : "proxy OFF"
        print("\(state) on \(primary.displayName)")

        // A write that could not happen is reported, never assumed away.
        switch controller.obstruction {
        case .awaitingUser:
            FileHandle.standardError.write(Data("not applied: needs an admin password\n".utf8))
            return 1
        case .foreignProxy(let existing):
            let host = existing?.host ?? "another proxy"
            FileHandle.standardError.write(Data("not applied: \(host) was set outside Siphon\n".utf8))
            return 1
        case .failed(_, let message):
            FileHandle.standardError.write(Data("not applied: \(message)\n".utf8))
            return 1
        case nil:
            return 0
        }
    }
}
