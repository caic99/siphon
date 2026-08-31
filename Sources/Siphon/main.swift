import AppKit

// Headless launch arguments (--on, --off, --toggle, --probe) do their work and
// exit; with none of them Siphon runs as a menu bar app.
if let exitCode = Command.run(CommandLine.arguments) {
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
