import Foundation

/// One command to run as root. `input` is fed to stdin — that is how `scutil`
/// takes its dictionary language.
public struct PrivilegedCommand: Equatable, Sendable {
    public let path: String
    public let arguments: [String]
    public let input: String?

    public init(path: String, arguments: [String] = [], input: String? = nil) {
        self.path = path
        self.arguments = arguments
        self.input = input
    }
}

public enum PrivilegeOutcome: Equatable, Sendable {
    case success
    /// The user dismissed the admin dialog. Not an error — they said no.
    case cancelled
    case failure(String)
}

/// Turns commands into the shell and AppleScript strings the prompt fallback
/// needs. Pure and separately testable: a quoting bug here would run the wrong
/// command as root.
public enum Shell {
    /// Single-quote for /bin/sh, closing and reopening around embedded quotes.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// A double-quoted AppleScript string literal.
    public static func appleScriptLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\""
    }

    public static func command(for command: PrivilegedCommand) -> String {
        let invocation = ([command.path] + command.arguments).map(quote).joined(separator: " ")
        guard let input = command.input else { return invocation }
        // printf rather than a heredoc: every line stays a quoted argument, so
        // nothing in the dictionary can terminate the command early.
        let lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let printf = (["/usr/bin/printf", "%s\n"] + lines).map(quote).joined(separator: " ")
        return "\(printf) | \(invocation)"
    }

    /// All commands as a single `do shell script`, so one toggle asks for the
    /// password at most once.
    public static func adminScript(for commands: [PrivilegedCommand]) -> String {
        let shell = commands.map(command(for:)).joined(separator: " && ")
        return "do shell script \(appleScriptLiteral(shell)) with administrator privileges"
    }
}

/// Runs commands as root: passwordless `sudo -n` when a sudoers rule allows it,
/// otherwise a native admin prompt.
///
/// The distinction matters beyond convenience. Automatic re-apply is only ever
/// attempted when `sudo -n` works, so a password dialog can never appear
/// without the user having clicked something.
public final class PrivilegeRunner {
    private static let sudo = "/usr/bin/sudo"
    private static let osascript = "/usr/bin/osascript"

    private var silentByPath: [String: Bool] = [:]

    public init() {}

    /// True when every path can run under `sudo` without a password prompt.
    /// Probed with `sudo -n -l`, which reports and exits rather than prompting.
    public func canRunSilently(_ paths: [String]) -> Bool {
        paths.allSatisfy { path in
            if let cached = silentByPath[path] { return cached }
            let result = Self.execute(Self.sudo, ["-n", "-l", path], input: nil)
            let allowed = result.status == 0
            silentByPath[path] = allowed
            return allowed
        }
    }

    public func invalidateProbe() { silentByPath.removeAll() }

    public func run(_ commands: [PrivilegedCommand], allowPrompt: Bool) -> PrivilegeOutcome {
        guard !commands.isEmpty else { return .success }

        if canRunSilently(commands.map(\.path)) {
            var failure: String?
            for command in commands {
                let result = Self.execute(Self.sudo, ["-n", command.path] + command.arguments,
                                          input: command.input)
                if result.status != 0 {
                    failure = result.errorText.isEmpty
                        ? "\(command.path) exited \(result.status)"
                        : result.errorText
                    break
                }
            }
            guard let failure else { return .success }
            // The rule may have changed under us. Re-probe, and let the prompt
            // path try again when the caller allows it.
            invalidateProbe()
            guard allowPrompt else { return .failure(failure) }
        }

        guard allowPrompt else {
            return .failure("Passwordless sudo is not available for this command.")
        }
        return runWithPrompt(commands)
    }

    private func runWithPrompt(_ commands: [PrivilegedCommand]) -> PrivilegeOutcome {
        let result = Self.execute(Self.osascript, ["-e", Shell.adminScript(for: commands)], input: nil)
        if result.status == 0 { return .success }
        // osascript reports a dismissed authorization dialog as error -128.
        if result.errorText.contains("-128") || result.errorText.contains("User canceled") {
            return .cancelled
        }
        return .failure(result.errorText.isEmpty
            ? "osascript exited \(result.status)"
            : result.errorText)
    }

    private static func execute(_ path: String, _ arguments: [String],
                                input: String?) -> (status: Int32, errorText: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments

        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        let inputPipe = Pipe()
        if input != nil { process.standardInput = inputPipe }

        do { try process.run() } catch { return (-1, error.localizedDescription) }

        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        // Commands here emit at most a few lines, well under the pipe buffer.
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let text = String(data: errorData, encoding: .utf8) ?? ""
        return (process.terminationStatus, text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
