import Foundation
import LetItBrewCore

/// Executes the app half of the exact-target handoff with injected I/O.  The
/// coordinator deliberately owns the selected URL for the whole operation:
/// inspection, helper stdin, and post-helper inspection cannot drift from a
/// recorded target to a newly configured ambient path.
public enum AgentExactRefreshCoordinator {
    public struct Presentation: Sendable, Equatable {
        public let trustTarget: URL?
        public let isConnected: Bool
        public let changedVendorBytes: Bool
        public var shouldRestartSessions: Bool { changedVendorBytes }
    }

    public static func presentation(agent: AgentID, selectedTarget: URL, helperSucceeded: Bool, finalInspection: AgentExactPreparation.Inspection, changedVendorBytes: Bool) -> Presentation {
        let connected = helperSucceeded && finalInspection == .healthyOwned
        return Presentation(trustTarget: agent == .codex ? selectedTarget : nil, isConnected: connected, changedVendorBytes: connected && changedVendorBytes)
    }
    public struct Observation: Sendable, Equatable {
        public let snapshot: ExactFileSnapshot
        public let inspection: AgentExactPreparation.Inspection
        public init(snapshot: ExactFileSnapshot, inspection: AgentExactPreparation.Inspection) {
            self.snapshot = snapshot
            self.inspection = inspection
        }
    }

    public struct Result: Sendable, Equatable {
        public let target: URL
        public let request: Data?
        public let helperInvoked: Bool
        public let helperSucceeded: Bool
        public let initial: Observation
        public let final: Observation
        public let completion: AgentExactPreparation.Completion
    }

    /// `inspect` and `launch` are intentionally synchronous closures: the
    /// desktop model calls them on its existing worker, while tests can prove
    /// the exact target and stdin without launching a real helper.
    public static func run(
        agent: AgentID,
        recordedTarget: String?,
        firstConnectResolvedTarget: URL,
        inspect: (URL) throws -> Observation,
        launch: (AgentID, Data) -> Bool
    ) throws -> Result {
        let target = recordedTarget.map(URL.init(fileURLWithPath:)) ?? firstConnectResolvedTarget
        let initial = try inspect(target)
        let decision = try AgentExactPreparation.decide(
            agent: agent,
            recordedTarget: recordedTarget,
            firstConnectResolvedTarget: firstConnectResolvedTarget,
            snapshot: initial.snapshot,
            inspection: initial.inspection
        )
        guard let request = decision.input else {
            return Result(
                target: target, request: nil, helperInvoked: false, helperSucceeded: false,
                initial: initial, final: initial,
                completion: AgentExactPreparation.completion(changesVendorBytes: false, helperSucceeded: false)
            )
        }
        let helperSucceeded = launch(agent, request)
        let final = helperSucceeded ? try inspect(target) : initial
        return Result(
            target: target, request: request, helperInvoked: true, helperSucceeded: helperSucceeded,
            initial: initial, final: final,
            completion: AgentExactPreparation.completion(
                changesVendorBytes: decision.changesVendorBytes,
                helperSucceeded: helperSucceeded
            )
        )
    }
}
