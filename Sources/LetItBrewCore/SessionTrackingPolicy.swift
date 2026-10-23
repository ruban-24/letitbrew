import Foundation

/// The exact hook/fallback revision the person chose to stop tracking.
/// Keeping this value instead of only a session id lets a later genuine work
/// edge automatically re-enable tracking for the same long-lived agent chat.
public struct SessionTrackingSuppression: Codable, Equatable, Sendable {
    public struct Key: Codable, Equatable, Hashable, Sendable {
        public let toolID: String
        public let sessionID: String

        public init(session: SessionRecord) {
            toolID = session.tool.lowercased()
            sessionID = session.id
        }
    }

    public struct Revision: Codable, Equatable, Sendable {
        public let state: SessionState
        public let updatedAt: Date
        public let eventObservedAt: TimeInterval?
        public let lastEvent: String?
        public let stateTransitionID: String?

        public init(session: SessionRecord) {
            state = session.state
            updatedAt = session.updatedAt
            eventObservedAt = session.eventObservedAt
            lastEvent = session.lastEvent
            stateTransitionID = session.stateTransitionID
        }
    }

    public let key: Key
    public let revision: Revision

    public var sessionID: String { key.sessionID }
    public var toolID: String { key.toolID }

    public init(session: SessionRecord) {
        key = Key(session: session)
        revision = Revision(session: session)
    }

    private init(key: Key, revision: Revision) {
        self.key = key
        self.revision = revision
    }

    fileprivate func advancing(to session: SessionRecord) -> Self {
        Self(key: key, revision: Revision(session: session))
    }
}

public struct SessionTrackingResult: Equatable, Sendable {
    public let sessions: [SessionRecord]
    public let suppressions: [SessionTrackingSuppression]

    public init(
        sessions: [SessionRecord],
        suppressions: [SessionTrackingSuppression]
    ) {
        self.sessions = sessions
        self.suppressions = suppressions
    }
}

/// Applies durable, per-session “Stop Tracking” choices to both the menu and
/// hold-decision snapshot. Suppression survives app relaunches, but a newer
/// working edge from that same session automatically clears it.
public enum SessionTrackingPolicy {
    public static func applying(
        _ suppressions: [SessionTrackingSuppression],
        to sessions: [SessionRecord]
    ) -> SessionTrackingResult {
        var indexed: [SessionTrackingSuppression.Key: SessionTrackingSuppression] = [:]
        for suppression in suppressions {
            indexed[suppression.key] = suppression
        }

        var visible: [SessionRecord] = []
        visible.reserveCapacity(sessions.count)
        for session in sessions {
            let key = SessionTrackingSuppression.Key(session: session)
            guard let suppression = indexed[key] else {
                visible.append(session)
                continue
            }

            let revision = SessionTrackingSuppression.Revision(session: session)
            guard revision != suppression.revision else { continue }

            if isGenuineWorkEdge(session) {
                indexed.removeValue(forKey: key)
                visible.append(session)
            } else {
                // Idle updates do not resurrect a row. Advance the watermark
                // so the next genuine work edge remains newer.
                indexed[key] = suppression.advancing(to: session)
            }
        }

        return SessionTrackingResult(
            sessions: visible,
            suppressions: indexed.values.sorted {
                ($0.toolID, $0.sessionID) < ($1.toolID, $1.sessionID)
            }
        )
    }

    /// A turn that ended in monitoring, or an edge that only renews it, is
    /// not new work, so it does not bring back a row the person stopped watching.
    private static func isGenuineWorkEdge(_ session: SessionRecord) -> Bool {
        session.state == .working && !HookSessionUpdater.isWaitingOnBackgroundWork(session)
    }
}
