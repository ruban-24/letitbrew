import LetItBrewCore

public struct AgentSessionVisibilityApplication: Equatable, Sendable {
    public let sessions: [SessionRecord]
    public let suppressions: [SessionTrackingSuppression]
}

/// Single composition shared by polling and synchronous connection actions.
public enum AgentSessionVisibilityPipeline {
    public static func apply(
        sessions: [SessionRecord],
        connectedAgentIDs: Set<String>,
        suppressions: [SessionTrackingSuppression]
    ) -> AgentSessionVisibilityApplication {
        let visible = AgentSessionVisibilityPolicy.visibleSessions(
            from: sessions, connectedAgentIDs: connectedAgentIDs
        )
        let tracked = SessionTrackingPolicy.applying(suppressions, to: visible)
        return .init(sessions: tracked.sessions, suppressions: tracked.suppressions)
    }
}
