import LetItBrewCore

public enum AgentConnectionAction: Equatable, Sendable { case connect, disconnect }
public struct AgentConnectionHelperCompletion: Equatable, Sendable {
    public let selectedAgentIDs: Set<String>
    public let state: AgentConnectionState
    public let details: [String]
    public let disposition: AgentConnectionDisposition
}
public enum AgentConnectionActionCoordinator {
    public static func perform(_ action: AgentConnectionAction, id: String, selected: Set<String>, persist: (Set<String>) -> Void, refreshVisibility: (Set<String>) -> Void, launchHelper: (AgentConnectionAction, String) -> Void) {
        guard AgentID(rawValue: id) != nil else { return }
        let next = action == .connect ? AgentConnectionSelectionPolicy.selecting(id, in: selected) : AgentConnectionSelectionPolicy.deselecting(id, from: selected)
        persist(next); refreshVisibility(next); launchHelper(action, id)
    }

    /// A helper completion can change presentation only.  It deliberately has
    /// no persistence callback, so a late connect/disconnect failure cannot
    /// roll a user's explicit selection backward or resurrect a deselection.
    public static func complete(
        _ action: AgentConnectionAction,
        id: String,
        selectedAgentIDs: Set<String>,
        result: AgentHelperOperationResult
    ) -> AgentConnectionHelperCompletion {
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded {
            switch action {
            case .disconnect:
                return .init(
                    selectedAgentIDs: selectedAgentIDs,
                    state: .actionNeeded,
                    details: ["Disconnected. Choose Connect to use this agent with Let It Brew."],
                    disposition: .intentionallyDisconnected
                )
            case .connect:
                return .init(
                    selectedAgentIDs: selectedAgentIDs,
                    state: .connecting,
                    details: [],
                    disposition: .managed
                )
            }
        }
        let name = AgentID(rawValue: id)?.displayName ?? id
        let fallback = action == .disconnect
            ? "Couldn’t disconnect \(name). Choose Disconnect again to retry removal."
            : "Couldn’t connect \(name). Choose Check Again."
        return .init(
            selectedAgentIDs: selectedAgentIDs,
            state: .couldNotConnect,
            details: [output.isEmpty ? fallback : output],
            disposition: action == .disconnect ? .disconnectFailed : .managed
        )
    }
}
