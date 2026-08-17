import LetItBrewCore

public struct AgentUninstallRowCompletion: Equatable, Sendable {
    public let agentID: String
    public let state: AgentConnectionState
    public let details: [String]
    public let disposition: AgentConnectionDisposition

    public init(agentID: String, state: AgentConnectionState, details: [String], disposition: AgentConnectionDisposition) {
        self.agentID = agentID
        self.state = state
        self.details = details
        self.disposition = disposition
    }
}

/// The completion authority deliberately carries the already-cleared intent
/// forward.  A late helper failure may add diagnostics and retry affordances,
/// but has no mechanism to repersist or reconnect an agent.
public struct AgentUninstallCompletion: Equatable, Sendable {
    public let selectedAgentIDs: Set<String>
    public let rows: [AgentUninstallRowCompletion]
    public let retryAgentIDs: Set<String>

    public init(selectedAgentIDs: Set<String>, rows: [AgentUninstallRowCompletion], retryAgentIDs: Set<String>) {
        self.selectedAgentIDs = selectedAgentIDs
        self.rows = rows
        self.retryAgentIDs = retryAgentIDs
    }
}

/// Positive selection is cleared before any best-effort helper removal.  A
/// failed removal therefore cannot authorize a later install/repair pass.
public enum AgentUninstallHooksCoordinator {
    public static func perform(
        selected: Set<String>,
        persist: (Set<String>) -> Void,
        refreshVisibility: (Set<String>) -> Void,
        launchRemoval: (Set<String>) -> Void
    ) {
        _ = selected
        let none: Set<String> = []
        persist(none)
        refreshVisibility(none)
        launchRemoval(Set(AgentID.allCases.map(\.rawValue)))
    }

    public static func complete(_ results: [AgentHelperOperationResult]) -> AgentUninstallCompletion {
        let byID = Dictionary(uniqueKeysWithValues: results.map { ($0.agentID, $0) })
        let rows = AgentID.allCases.map { agent -> AgentUninstallRowCompletion in
            guard let result = byID[agent.rawValue], !result.succeeded else {
                return .init(
                    agentID: agent.rawValue,
                    state: .actionNeeded,
                    details: ["Disconnected. Choose Connect to use this agent with Let It Brew."],
                    disposition: .intentionallyDisconnected
                )
            }
            let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = output.isEmpty
                ? "Couldn’t disconnect \(agent.displayName). Choose Disconnect again to retry removal."
                : output
            return .init(
                agentID: agent.rawValue,
                state: .couldNotConnect,
                details: [detail, "The connection is deselected. Choose Disconnect again to retry removal."],
                disposition: .disconnectFailed
            )
        }
        return .init(
            selectedAgentIDs: [],
            rows: rows,
            retryAgentIDs: Set(results.filter { !$0.succeeded }.map(\.agentID))
        )
    }
}
