import Foundation
import LetItBrewCore

public enum AgentConfigurationInspectionState: Equatable, Sendable {
    case absent, healthyOwned, repairableOwned, invalid
    var exactTargetExpectedState: ExactTargetExpectedState? {
        switch self {
        case .absent: .absent
        case .healthyOwned: .healthyOwned
        case .repairableOwned: .repairableOwned
        case .invalid: nil
        }
    }
}

public struct AgentConnectionInspection: Equatable, Sendable {
    public let agentID: String
    public let state: AgentConfigurationInspectionState
    public let hasRecordedTarget: Bool
    public let exactTargetSnapshot: ExactFileSnapshot?
    public let selectedTarget: URL?
    public init(agentID: String, state: AgentConfigurationInspectionState, hasRecordedTarget: Bool, exactTargetSnapshot: ExactFileSnapshot?, selectedTarget: URL? = nil) {
        self.agentID = agentID
        self.state = state
        self.hasRecordedTarget = hasRecordedTarget
        self.exactTargetSnapshot = exactTargetSnapshot
        self.selectedTarget = selectedTarget
    }
}

public enum AgentLaunchPreparation: Equatable, Sendable {
    case recordedTarget(agentID: String)
    case exactTarget(agentID: String, expectedState: ExactTargetExpectedState, snapshot: ExactFileSnapshot)
}

public struct AgentLaunchConnectionDecision: Equatable, Sendable {
    public let selectedAgentIDs: Set<String>
    public let preparations: [AgentLaunchPreparation]
}

public enum AgentLaunchConnectionPolicy {
    public static func decision(persistedSelection: [String]?, legacyDisconnected: Set<String>, inspections: [AgentConnectionInspection], legacyMigratableAgentIDs: Set<String>) -> AgentLaunchConnectionDecision {
        let supported = Set(AgentID.allCases.map(\.rawValue))
        var byID: [String: AgentConnectionInspection] = [:]
        for inspection in inspections where supported.contains(inspection.agentID) && byID[inspection.agentID] == nil {
            byID[inspection.agentID] = inspection
        }
        let selected: Set<String>
        if let persistedSelection {
            selected = Set(persistedSelection).intersection(supported)
        } else {
            let legacy = legacyMigratableAgentIDs.intersection(["claude", "codex"]).intersection(supported)
            selected = Set(byID.values.compactMap { inspection in
                legacy.contains(inspection.agentID)
                    && (inspection.state == .healthyOwned || inspection.state == .repairableOwned)
                    && !legacyDisconnected.contains(inspection.agentID)
                    ? inspection.agentID : nil
            })
        }
        let preparations = selected.sorted().compactMap { id -> AgentLaunchPreparation? in
            guard let inspection = byID[id], inspection.state != .invalid else { return nil }
            if inspection.hasRecordedTarget {
                return inspection.state == .healthyOwned ? nil : .recordedTarget(agentID: id)
            }
            guard let snapshot = inspection.exactTargetSnapshot,
                  let state = inspection.state.exactTargetExpectedState else { return nil }
            return .exactTarget(agentID: id, expectedState: state, snapshot: snapshot)
        }
        return .init(selectedAgentIDs: selected, preparations: preparations)
    }
}
