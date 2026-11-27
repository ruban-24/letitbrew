import Foundation
internal import UserNotifications

/// The person's notification choice for Let It Brew.
@frozen
public enum AlertNotificationAuthorization: Sendable, Equatable {
    case notDetermined
    case allowed
    case denied
}

/// The only code that touches the system notification framework. It lives in
/// this embedded framework so the app's main executable does not link
/// UserNotifications: Let It Brew 1.0.x refuses an update whose main executable
/// does. Policy and wording stay in LetItBrewAppCore; this only posts.
@MainActor
public final class AlertNotifications {
    public static let shared = AlertNotifications()

    fileprivate nonisolated static let agentPIDKey = "agentPID"
    private var center: UNUserNotificationCenter { .current() }
    private var delegate: ClickDelegate?

    private init() {}

    /// Must run before launch finishes, so a click that launched the app
    /// still reaches the delegate. `onClick` gets the clicked alert's agent PID.
    public func install(onClick: @escaping @MainActor (Int32) -> Void) {
        let delegate = ClickDelegate(onClick: onClick)
        self.delegate = delegate
        center.delegate = delegate
    }

    public func post(identifier: String, title: String, body: String, agentPID: Int32?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let agentPID {
            content.userInfo = [Self.agentPIDKey: Int(agentPID)]
        }
        center.add(UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        ))
    }

    /// Asks once; later calls report the person's choice. Alerts are
    /// banners only: alert sounds are out of scope.
    public func requestAuthorization() async -> AlertNotificationAuthorization {
        _ = try? await center.requestAuthorization(options: [.alert])
        return await authorization()
    }

    public func authorization() async -> AlertNotificationAuthorization {
        switch await center.notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        default: .allowed
        }
    }
}

/// The notification center keeps only a weak reference, so
/// `AlertNotifications` holds this for the life of the app.
private final class ClickDelegate: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private let onClick: @MainActor (Int32) -> Void

    init(onClick: @escaping @MainActor (Int32) -> Void) {
        self.onClick = onClick
    }

    // The menu or Settings may be frontmost; show the banner anyway.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let pid = response.notification.request.content.userInfo[AlertNotifications.agentPIDKey] as? Int
        else { return }
        let agentPID = Int32(pid)
        await MainActor.run {
            onClick(agentPID)
        }
    }
}
