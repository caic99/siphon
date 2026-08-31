import Foundation

/// The shell commands that point a terminal at the same proxy the Mac is using.
///
/// System proxy settings do not reach command-line tools — curl, git, pip and
/// friends read environment variables instead. This mirrors the *service's own*
/// configuration, exception list included, so a terminal bypasses exactly what
/// the rest of the system bypasses.
public enum ShellExports {
    /// `ExcludeSimpleHostnames` has no `no_proxy` equivalent — the variable
    /// matches suffixes and exact hosts, not "any name without a dot" — so it
    /// is deliberately not represented here beyond the loopback names below.
    public static func commands(for server: ProxyServer, exceptions: [String]) -> String {
        let url = "http://\(server.host):\(server.port)"
        let bypass = noProxy(exceptions: exceptions)
        return """
        export http_proxy=\(url)
        export https_proxy=\(url)
        export no_proxy=\(bypass)
        export HTTP_PROXY="$http_proxy" HTTPS_PROXY="$https_proxy" NO_PROXY="$no_proxy"
        """
    }

    /// Translates a macOS exception list into `no_proxy` syntax.
    ///
    /// Loopback leads unconditionally: macOS bypasses it whether or not it is
    /// listed, while shell tools honour only what this variable says, so
    /// omitting it would proxy a terminal's localhost traffic and nothing else
    /// on the Mac's.
    static func noProxy(exceptions: [String]) -> String {
        var entries = ["localhost", "127.0.0.1"]
        for exception in exceptions {
            // "*.example.com" is macOS's wildcard; no_proxy spells the same
            // thing as a leading dot.
            let entry = exception.hasPrefix("*.")
                ? String(exception.dropFirst())
                : exception
            let trimmed = entry.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !entries.contains(trimmed) else { continue }
            entries.append(trimmed)
        }
        return entries.joined(separator: ",")
    }
}
