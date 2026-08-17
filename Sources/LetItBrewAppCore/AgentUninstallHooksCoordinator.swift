import LetItBrewCore

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
}
