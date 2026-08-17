import Foundation
import LetItBrewCore

/// The launch path may inspect all catalog targets, but it must never start a
/// Codex trust probe unless the user positively selected Codex.  The target is
/// the immutable target handed over by the original disk inspection; this
/// boundary deliberately has no configured-target or environment input.
public enum AgentLaunchTrustCoordinator {
    public static func selectedCodexTrust(
        selectedAgentIDs: Set<String>,
        inspections: [AgentConnectionInspection],
        inspect: (URL) -> CodexHookTrustResult
    ) -> CodexHookTrustResult? {
        guard selectedAgentIDs.contains(AgentID.codex.rawValue),
              let codex = inspections.first(where: { $0.agentID == AgentID.codex.rawValue }),
              codex.state != .invalid,
              let target = codex.selectedTarget
        else { return nil }
        return inspect(target)
    }
}
