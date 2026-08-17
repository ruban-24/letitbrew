import LetItBrewCore

public enum AgentConnectionAction: Equatable, Sendable { case connect, disconnect }
public enum AgentConnectionActionCoordinator {
    public static func perform(_ action: AgentConnectionAction, id: String, selected: Set<String>, persist: (Set<String>) -> Void, refreshVisibility: (Set<String>) -> Void, launchHelper: (AgentConnectionAction, String) -> Void) {
        guard AgentID(rawValue: id) != nil else { return }
        let next = action == .connect ? AgentConnectionSelectionPolicy.selecting(id, in: selected) : AgentConnectionSelectionPolicy.deselecting(id, from: selected)
        persist(next); refreshVisibility(next); launchHelper(action, id)
    }
}
