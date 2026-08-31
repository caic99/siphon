import AppKit

// Headless launch arguments (--on, --off, --toggle, --probe) do their work and
// exit; with none of them Siphon runs as a menu bar app.
// Maintenance tool, deliberately absent from --help.
if let flag = CommandLine.arguments.firstIndex(of: "--screenshot"),
   CommandLine.arguments.indices.contains(flag + 1) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    Screenshot.capture(to: CommandLine.arguments[flag + 1])
    exit(0)
}

if let exitCode = Command.run(CommandLine.arguments) {
    exit(exitCode)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
