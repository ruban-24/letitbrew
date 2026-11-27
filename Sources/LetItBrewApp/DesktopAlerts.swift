import AppKit
import CoreGraphics
import LetItBrewAlerts
import LetItBrewAppCore
import Network

/// Hands finished alerts to a channel. `AlertPolicy` has already decided
/// what to send and written its text; delivery never affects the hold.
@MainActor
protocol AlertDelivering: AnyObject {
    func deliver(_ alerts: [Alert])
}

@MainActor
final class NoAlertDelivery: AlertDelivering {
    func deliver(_ alerts: [Alert]) {}
}

enum DesktopAlertAuthorization: Equatable {
    case notDetermined
    case allowed
    case denied
}

/// Desktop alerts through the system notification framework, which only
/// `LetItBrewAlerts` touches. Clicking an alert brings the session's app
/// forward.
@MainActor
final class DesktopAlerts: AlertDelivering {
    static let shared = DesktopAlerts()

    private var notifications: AlertNotifications { .shared }

    /// Must run before launch finishes, so a click that launched the app
    /// still reaches the delegate.
    func install() {
        notifications.install { agentPID in
            _ = SessionHostActivator.activate(agentPID: agentPID)
        }
    }

    func deliver(_ alerts: [Alert]) {
        for alert in alerts where alert.destinations.contains(.desktop) {
            notifications.post(
                identifier: alert.id,
                title: alert.title,
                body: alert.body,
                agentPID: alert.agentPID
            )
        }
    }

    /// Asks once; later calls report the person's choice.
    func requestAuthorization() async -> DesktopAlertAuthorization {
        DesktopAlertAuthorization(await notifications.requestAuthorization())
    }

    func authorization() async -> DesktopAlertAuthorization {
        DesktopAlertAuthorization(await notifications.authorization())
    }

    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }
}

private extension DesktopAlertAuthorization {
    init(_ authorization: AlertNotificationAuthorization) {
        switch authorization {
        case .notDetermined: self = .notDetermined
        case .allowed: self = .allowed
        case .denied: self = .denied
        }
    }
}

/// Whether the person is at the Mac, for the alert policy.
enum AlertPresenceReader {
    static func current(lidClosed: Bool, externalDisplay: Bool) -> AlertPresence {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        let locked = session?["CGSSessionScreenIsLocked"] as? Bool ?? false
        let anyInput = CGEventType(rawValue: ~0)!
        return AlertPresence(
            lidClosed: lidClosed,
            screenLocked: locked,
            secondsSinceLastInput: CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: anyInput
            ),
            externalDisplay: externalDisplay
        )
    }
}

/// Whether the Mac can reach a network, for the Wi-Fi alert. Nil until the
/// first reading, so launch never counts as a drop.
final class NetworkReachability: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var reachable: Bool?

    var isReachable: Bool? {
        lock.withLock { reachable }
    }

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.reachable = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.ruban24.letitbrew.network"))
    }
}
