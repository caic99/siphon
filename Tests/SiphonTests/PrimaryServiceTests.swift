import XCTest
@testable import SiphonCore

final class PrimaryServiceTests: XCTestCase {
    func testClassifiesTunnelInterfaces() {
        for interface in ["utun0", "utun14", "ppp0", "tun3", "tap0"] {
            XCTAssertTrue(PrimaryService.isTunnelInterface(interface), interface)
        }
        for interface in ["en0", "en7", "bridge0", "lo0", "awdl0"] {
            XCTAssertFalse(PrimaryService.isTunnelInterface(interface), interface)
        }
    }

    /// Tunnels have no networksetup service, so their proxies live in the
    /// dynamic State: store; physical services persist theirs in Setup:.
    func testProxyKeyFollowsTheInterfaceKind() {
        let tunnel = PrimaryService(serviceID: "ABC", interface: "utun4", name: "VPN")
        XCTAssertEqual(tunnel.proxyKey, "State:/Network/Service/ABC/Proxies")

        let wired = PrimaryService(serviceID: "DEF", interface: "en7", name: "USB LAN")
        XCTAssertEqual(wired.proxyKey, "Setup:/Network/Service/DEF/Proxies")
    }

    func testTargetInheritsTheServiceKey() {
        let service = PrimaryService(serviceID: "ABC", interface: "utun4", name: "VPN")
        XCTAssertEqual(ProxyTarget(service).proxyKey, service.proxyKey)
    }

    func testDisplayNameNamesTheInterface() {
        let service = PrimaryService(serviceID: "DEF", interface: "en7", name: "USB LAN")
        XCTAssertEqual(service.displayName, "USB LAN (en7)")
    }

    /// A tunnel's name falls back to its interface; saying it twice is noise.
    func testDisplayNameDoesNotRepeatTheInterface() {
        let tunnel = PrimaryService(serviceID: "ABC", interface: "utun4", name: "utun4")
        XCTAssertEqual(tunnel.displayName, "utun4")
    }
}
