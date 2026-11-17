import AppKit
import CoreGraphics
import LetItBrewAppCore
import Network
@preconcurrency import UserNotifications

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

/// Desktop alerts through the system notification framework. Clicking an
/// alert brings the session's app forward.
@MainActor
final class DesktopAlerts: NSObject, AlertDelivering, UNUserNotificationCenterDelegate {
    static let shared = DesktopAlerts()

    private nonisolated static let agentPIDKey = "agentPID"
    private var center: UNUserNotificationCenter { .current() }

    /// Must run before launch finishes, so a click that launched the app
    /// still reaches the delegate.
    func install() {
        center.delegate = self
    }

    func deliver(_ alerts: [Alert]) {
        for alert in alerts where alert.destinations.contains(.desktop) {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            if let pid = alert.agentPID {
                content.userInfo = [Self.agentPIDKey: Int(pid)]
            }
            center.add(UNNotificationRequest(
                identifier: alert.id,
                content: content,
                trigger: nil
            ))
        }
    }

    /// Asks once; later calls report the person's choice. Alerts are
    /// banners only: alert sounds are out of scope.
    func requestAuthorization() async -> DesktopAlertAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert])
        return await authorization()
    }

    func authorization() async -> DesktopAlertAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }

    static func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // The menu or Settings may be frontmost; show the banner anyway.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let pid = response.notification.request.content.userInfo[Self.agentPIDKey] as? Int
        else { return }
        let agentPID = Int32(pid)
        await MainActor.run {
            _ = SessionHostActivator.activate(agentPID: agentPID)
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
