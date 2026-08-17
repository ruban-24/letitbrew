import LetItBrewCore

/// A deliberately small persistence boundary for the one-time move from the
/// old negative key to V2 positive selection.  `malformed` is authoritative
/// empty intent, never permission to consult legacy state.
public enum AgentPersistedSelection: Equatable, Sendable {
    case missing
    case values([String])
    case malformed
}

public struct AgentConnectionMigrationResult: Equatable, Sendable {
    public let decision: AgentLaunchConnectionDecision
    public let consultedLegacy: Bool
    public init(decision: AgentLaunchConnectionDecision, consultedLegacy: Bool) {
        self.decision = decision
        self.consultedLegacy = consultedLegacy
    }
}

public enum AgentConnectionMigration {
    public static func migrate(
        persisted: AgentPersistedSelection,
        legacyDisconnected: Set<String>,
        inspections: [AgentConnectionInspection],
        legacyMigratableAgentIDs: Set<String>
    ) -> AgentConnectionMigrationResult {
        let missing = persisted == .missing
        let selection: [String]? = switch persisted {
        case .missing: nil
        case .values(let values): values
        case .malformed: []
        }
        return .init(
            decision: AgentLaunchConnectionPolicy.decision(
                persistedSelection: selection,
                legacyDisconnected: missing ? legacyDisconnected : [],
                inspections: inspections,
                legacyMigratableAgentIDs: missing ? legacyMigratableAgentIDs : []
            ),
            consultedLegacy: missing
        )
    }
}
