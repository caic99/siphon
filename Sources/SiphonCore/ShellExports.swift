import Foundation

/// The shell commands that point a terminal at the proxy.
///
/// System proxy settings do not reach command-line tools — curl, git and pip
/// read environment variables instead.
public enum ShellExports {
    public static func commands(for server: ProxyServer) -> String {
        let url = "http://\(server.host):\(server.port)"
        return """
        export HTTP_PROXY=\(url)
        export HTTPS_PROXY=\(url)
        """
    }
}
