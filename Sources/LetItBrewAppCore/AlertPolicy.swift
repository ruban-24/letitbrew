import Foundation
import LetItBrewCore

/// What the person turned on in Settings → Alerts. Alerts are opt-in: a new
/// install and an update from 1.x both start with desktop alerts off.
public struct AlertSettings: Equatable, Sendable {
    public var desktopAlerts: Bool
    public var needsYou: Bool
    public var hideProjectNames: Bool

    public init(
        desktopAlerts: Bool = false,
        needsYou: Bool = true,
        hideProjectNames: Bool = false
    ) {
        self.desktopAlerts = desktopAlerts
        self.needsYou = needsYou
        self.hideProjectNames = hideProjectNames
    }
}

/// Whether the person is at the Mac. The needs-you rule does not use it;
/// phone alerts go out only when the person is away.
public struct AlertPresence: Equatable, Sendable {
    public let lidClosed: Bool
    public let screenLocked: Bool
    public let secondsSinceLastInput: TimeInterval

    public init(lidClosed: Bool, screenLocked: Bool, secondsSinceLastInput: TimeInterval) {
        self.lidClosed = lidClosed
        self.screenLocked = screenLocked
        self.secondsSinceLastInput = secondsSinceLastInput
    }
}

public enum AlertWaitKind: Equatable, Sendable {
    case approval
    case answer
}

/// One session as alerts see it. There is deliberately no field for prompt
/// text, questions, tool names, or commands, so none can reach an alert.
public struct AlertSessionObservation: Equatable, Sendable {
    public let id: String
    /// The agent's tool identifier, such as "claude".
    public let agent: String
    /// The project folder's name.
    public let project: String
    /// Nil unless the session is Waiting on the person as the menu shows it:
    /// a wait whose approved command is running counts as Working.
    public let wait: AlertWaitKind?
    /// When the record last changed state.
    public let stateChangedAt: Date
    /// Brings the session's app forward when the alert is clicked.
    public let agentPID: Int32?

    public init(
        id: String,
        agent: String,
        project: String,
        wait: AlertWaitKind?,
        stateChangedAt: Date,
        agentPID: Int32?
    ) {
        self.id = id
        self.agent = agent
        self.project = project
        self.wait = wait
        self.stateChangedAt = stateChangedAt
        self.agentPID = agentPID
    }
}

public struct AlertSessionState: Equatable, Sendable {
    public let observation: AlertSessionObservation
    /// Start of the current unbroken Waiting stretch, as seen by polling.
    public let waitingSince: Date?
}

/// The sessions at one poll, with how long each has been Waiting.
public struct AlertSnapshot: Equatable, Sendable {
    public let observedAt: Date
    public let sessions: [AlertSessionState]

    /// A record's state edge alone cannot time a wait: an approved command
    /// shows the session as Working while the record stays Waiting, and once
    /// it exits the session is Waiting again with the old edge. So a wait is
    /// timed from when polling first saw it, never before the previous poll.
    public init(
        observedAt: Date,
        sessions: [AlertSessionObservation],
        previous: AlertSnapshot?
    ) {
        self.observedAt = observedAt
        self.sessions = sessions.map { session in
            guard session.wait != nil else {
                return AlertSessionState(observation: session, waitingSince: nil)
            }
            let before = previous?.sessions.first { $0.observation.id == session.id }
            if let before,
               let since = before.waitingSince,
               before.observation.stateChangedAt == session.stateChangedAt {
                return AlertSessionState(observation: session, waitingSince: since)
            }
            let since = max(session.stateChangedAt, previous?.observedAt ?? .distantPast)
            return AlertSessionState(observation: session, waitingSince: since)
        }
    }
}

public enum AlertKind: Equatable, Sendable {
    case needsYou
}

public enum AlertDestination: Hashable, Sendable {
    case desktop
}

public struct Alert: Equatable, Sendable, Identifiable {
    /// Stable per episode, so a repeated delivery replaces rather than stacks.
    public let id: String
    public let kind: AlertKind
    public let destinations: Set<AlertDestination>
    public let title: String
    public let body: String
    public let sessionID: String
    public let agentPID: Int32?
}

public enum AlertPolicy {
    public static let needsYouDelay: TimeInterval = 30

    /// Alerts for what changed between two polls, with final wording. An
    /// alert fires on the poll that crosses its threshold, so reapplying a
    /// snapshot repeats nothing. Without a previous snapshot there is no
    /// crossing: launching never alerts for a wait already under way.
    public static func alerts(
        previous: AlertSnapshot?,
        current: AlertSnapshot,
        presence: AlertPresence,
        settings: AlertSettings
    ) -> [Alert] {
        guard let previous else { return [] }
        var destinations: Set<AlertDestination> = []
        if settings.desktopAlerts { destinations.insert(.desktop) }
        guard settings.needsYou, !destinations.isEmpty else { return [] }

        return current.sessions.compactMap { state in
            guard let since = state.waitingSince,
                  let wait = state.observation.wait,
                  current.observedAt.timeIntervalSince(since) >= needsYouDelay
            else { return nil }
            let before = previous.sessions.first {
                $0.observation.id == state.observation.id && $0.waitingSince == since
            }
            if before != nil,
               previous.observedAt.timeIntervalSince(since) >= needsYouDelay {
                return nil
            }
            return needsYou(state.observation, wait: wait, since: since,
                            destinations: destinations, settings: settings)
        }
    }

    private static func needsYou(
        _ session: AlertSessionObservation,
        wait: AlertWaitKind,
        since: Date,
        destinations: Set<AlertDestination>,
        settings: AlertSettings
    ) -> Alert {
        var title = "\(agentName(session.agent)) needs you"
        if !settings.hideProjectNames, !session.project.isEmpty {
            title += " · \(session.project)"
        }
        let body = switch wait {
        case .approval: "Waiting for your approval"
        case .answer: "Waiting for your answer"
        }
        return Alert(
            id: "needs-you.\(session.id).\(since.timeIntervalSince1970)",
            kind: .needsYou,
            destinations: destinations,
            title: title,
            body: body,
            sessionID: session.id,
            agentPID: session.agentPID
        )
    }

    private static func agentName(_ tool: String) -> String {
        AgentID(rawValue: tool)?.displayName ?? "An agent"
    }
}

/// The one-time menu tip that offers alerts after updating.
public enum AlertsTipPolicy {
    public static let title = "Get alerts when an agent needs you?"
    public static let detail = "A desktop notification when an agent waits on you for 30 seconds."

    public static func isShown(dismissed: Bool, desktopAlerts: Bool) -> Bool {
        !dismissed && !desktopAlerts
    }
}
