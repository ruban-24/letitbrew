import LetItBrewCore

/// A deliberately small persistence boundary for the one-time move from the
/// old negative key to V2 positive selection.  `malformed` is authoritative
/// empty intent, never permission to consult legacy state.
public enum AgentPersistedSelection: Equatable, Sendable {
    case missing
    case values([String])
    case malformed
}

public enum AgentConnectionMigration {
    public static func migrate(
        persisted: AgentPersistedSelection,
        legacyDisconnected: Set<String>,
        inspections: [AgentConnectionInspection],
        legacyMigratableAgentIDs: Set<String>
    ) -> AgentLaunchConnectionDecision {
        let missing = persisted == .missing
        let selection: [String]? = switch persisted {
        case .missing: nil
        case .values(let values): values
        case .malformed: []
        }
        return AgentLaunchConnectionPolicy.decision(
            persistedSelection: selection,
            legacyDisconnected: missing ? legacyDisconnected : [],
            inspections: inspections,
            legacyMigratableAgentIDs: missing ? legacyMigratableAgentIDs : []
        )
    }

    /// The persistence ordering is intentional: a crash after the write
    /// leaves authoritative V2 selection; legacy intent is never the only
    /// remaining source after this boundary starts.
    public static func persist(
        _ selectedAgentIDs: Set<String>,
        writeV2: ([String]) -> Void,
        removeLegacy: () -> Void
    ) {
        writeV2(selectedAgentIDs.sorted())
        removeLegacy()
    }
}
