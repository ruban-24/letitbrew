import Foundation

/// Applies the user's durable per-agent Disconnect choices to the live
/// session snapshot consumed by both presentation and hold decisions.
///
/// This is deliberately a view over the records: disconnecting an agent must
/// never delete its session files, so reconnecting can expose a still-live
/// session again.
public enum AgentSessionVisibilityPolicy {
    public static func visibleSessions(
        from sessions: [SessionRecord],
        connectedAgentIDs: Set<String>
    ) -> [SessionRecord] {
        let normalizedIDs = Set(connectedAgentIDs.map { $0.lowercased() })
        return sessions.filter { normalizedIDs.contains($0.tool.lowercased()) }
    }
}
