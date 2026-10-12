import Foundation

/// The shell commands that point a terminal at the proxy.
///
/// System proxy settings do not reach command-line tools — curl, git and pip
/// read environment variables instead.
public enum ShellExports {
    public static func commands(for server: ProxyServer) -> String {
        let url = "http://\(server.host):\(server.port)"
        var out = """
        export HTTP_PROXY=\(url)
        export HTTPS_PROXY=\(url)
        """
        // A tunnel is also a SOCKS5 server; tools that take ALL_PROXY (curl,
        // git over libcurl, pip) can then skip the HTTP bridge. socks5h: the
        // far end resolves names, which is the point of tunnelling.
        if let socks = server.socksPort {
            out += "\nexport ALL_PROXY=socks5h://\(server.host):\(socks)"
        }
        return out
    }
}
