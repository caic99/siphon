import Foundation
import SystemConfiguration

/// Watches for the default route moving and for proxy settings changing under
/// us, so the menu never shows a stale answer and a service that has just taken
/// over the route can be re-proxied without the user asking.
public final class NetworkMonitor {
    /// Fired on the main queue after changes have settled.
    public var onChange: (() -> Void)?

    /// Interface-up, address assignment, and DNS updates arrive as a burst;
    /// applying a proxy on each one would issue several privileged writes for a
    /// single network change.
    private static let settleDelay: TimeInterval = 1.5

    private var store: SCDynamicStore?
    private var settleTimer: Timer?

    public init() {}

    public func start() {
        var context = SCDynamicStoreContext(version: 0,
                                            info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkMonitor>.fromOpaque(info).takeUnretainedValue().scheduleNotification()
        }
        guard let store = SCDynamicStoreCreate(nil, "Siphon.monitor" as CFString,
                                               callback, &context) else { return }
        SCDynamicStoreSetNotificationKeys(store,
                                          [NetworkState.globalIPv4Key] as CFArray,
                                          NetworkState.serviceProxiesPatterns as CFArray)
        SCDynamicStoreSetDispatchQueue(store, .main)
        self.store = store
    }

    private func scheduleNotification() {
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            self?.onChange?()
        }
        // .common so a burst that lands while the menu is open still settles.
        RunLoop.main.add(timer, forMode: .common)
        settleTimer = timer
    }

    deinit {
        settleTimer?.invalidate()
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
    }
}
