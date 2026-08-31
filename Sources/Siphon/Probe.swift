import Foundation
import SiphonCore

/// `Siphon --probe` reports everything Siphon can see and exits. Read-only: no
/// privileged command runs, nothing is written. Useful for checking what the
/// app resolves on a machine where the menu says something surprising.
enum Probe {
    static func run() {
        guard let primary = NetworkState.primaryService() else {
            print("primary service: none (nothing owns the default route)")
            return
        }
        let proxies = NetworkState.proxies(for: primary)
        print("primary service: \(primary.displayName)")
        print("  service id:    \(primary.serviceID)")
        print("  kind:          \(primary.isTunnel ? "tunnel (scutil)" : "physical (networksetup)")")
        print("  proxy key:     \(primary.proxyKey)")
        print("  proxy:         \(proxies.isOn ? "on" : "off")"
              + (proxies.server.map { " — \($0.display)" } ?? ""))
        print("  preserved:     \(proxies.entries.keys.sorted().joined(separator: ", "))")
        if !proxies.droppedKeys.isEmpty {
            print("  NOT preservable: \(proxies.droppedKeys.joined(separator: ", "))")
        }

        let discovered = NetworkState.discoverServers()
        print("discovered servers: "
              + (discovered.isEmpty ? "none" : discovered.map(\.display).joined(separator: ", ")))

        let controller = ProxyController()
        controller.refresh()
        print("selected server: \(controller.server?.display ?? "none")")
        print("menu would list:  "
              + controller.knownServers.map { $0 == controller.server ? "[\($0.display)]" : $0.display }
                  .joined(separator: ", "))

        let runner = PrivilegeRunner()
        let path = primary.isTunnel ? "/usr/sbin/scutil" : "/usr/sbin/networksetup"
        print("passwordless sudo for \(path): \(runner.canRunSilently([path]))")
    }
}
