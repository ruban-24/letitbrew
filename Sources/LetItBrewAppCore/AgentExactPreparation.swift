import Foundation
import LetItBrewCore

/// Pure app-side selection and handoff policy.  The app supplies its
/// read-only descriptor snapshot and executes the returned request; this type
/// never opens vendor configuration or launches a process.
public enum AgentExactPreparation {
    public enum Inspection: Sendable, Equatable { case absent, healthyOwned, repairableOwned, invalid }
    public struct Decision: Sendable {
        public let target: URL
        public let input: Data?
        public let changesVendorBytes: Bool
        public init(target: URL, input: Data?, changesVendorBytes: Bool) { self.target = target; self.input = input; self.changesVendorBytes = changesVendorBytes }
    }

    public static func decide(
        agent: AgentID, recordedTarget: String?, configuredTarget: URL,
        firstConnectResolvedTarget: URL, snapshot: ExactFileSnapshot,
        inspection: Inspection
    ) throws -> Decision {
        let target = recordedTarget.map(URL.init(fileURLWithPath:)) ?? firstConnectResolvedTarget
        guard target.standardizedFileURL.path == snapshot.path else { throw AgentExactPreparationError.snapshotTargetMismatch }
        switch inspection {
        case .invalid: return Decision(target: target, input: nil, changesVendorBytes: false)
        case .absent, .healthyOwned, .repairableOwned:
            let state: ExactTargetExpectedState = inspection == .absent ? .absent : inspection == .healthyOwned ? .healthyOwned : .repairableOwned
            let preparation = try ExactTargetPreparation(agent: agent, snapshot: snapshot, expectedState: state)
            return Decision(target: target, input: try JSONEncoder().encode(preparation), changesVendorBytes: state != .healthyOwned)
        }
    }
}
public enum AgentExactPreparationError: Error { case snapshotTargetMismatch }
