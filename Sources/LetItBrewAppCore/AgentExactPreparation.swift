import Foundation
import LetItBrewCore

/// Pure app-side selection and handoff policy.  The app supplies its
/// read-only descriptor snapshot and executes the returned request; this type
/// never opens vendor configuration or launches a process.
public enum AgentExactPreparation {
    public enum Inspection: Sendable, Equatable { case absent, healthyOwned, repairableOwned, invalid }
    public struct Decision: Sendable {
        public let input: Data?
        public let changesVendorBytes: Bool
        public init(input: Data?, changesVendorBytes: Bool) { self.input = input; self.changesVendorBytes = changesVendorBytes }
    }

    /// Presentation is derived from both the request's pure state and the
    /// helper result.  A failed helper must never cause a restart prompt.
    public struct Completion: Sendable, Equatable {
        public let changedVendorBytes: Bool
        public var shouldRestartSessions: Bool { changedVendorBytes }
    }

    public static func decide(
        agent: AgentID, recordedTarget: String?,
        firstConnectResolvedTarget: URL, snapshot: ExactFileSnapshot,
        inspection: Inspection
    ) throws -> Decision {
        let target = recordedTarget.map(URL.init(fileURLWithPath:)) ?? firstConnectResolvedTarget
        guard target.standardizedFileURL.path == snapshot.path else { throw AgentExactPreparationError.snapshotTargetMismatch }
        switch inspection {
        case .invalid: return Decision(input: nil, changesVendorBytes: false)
        case .absent, .healthyOwned, .repairableOwned:
            let state: ExactTargetExpectedState = inspection == .absent ? .absent : inspection == .healthyOwned ? .healthyOwned : .repairableOwned
            let preparation = try ExactTargetPreparation(agent: agent, snapshot: snapshot, expectedState: state)
            return Decision(input: try JSONEncoder().encode(preparation), changesVendorBytes: state != .healthyOwned)
        }
    }

    public static func completion(changesVendorBytes: Bool, helperSucceeded: Bool) -> Completion {
        Completion(changedVendorBytes: changesVendorBytes && helperSucceeded)
    }
}
public enum AgentExactPreparationError: Error { case snapshotTargetMismatch }
