import Foundation
import Testing
@testable import LetItBrewAppCore
import LetItBrewCore

private func absentSnapshot(_ path: String = "/tmp/exact-target") throws -> ExactFileSnapshot {
    try ExactFileSnapshot(path: path, exists: false)
}

@Test func exactPreparationEncodesEveryAgentAndMutationState() throws {
    for agent in AgentID.allCases {
        let snapshot = try absentSnapshot("/tmp/\(agent.rawValue)")
        for (inspection, expectedState, changes) in [
            (AgentExactPreparation.Inspection.absent, ExactTargetExpectedState.absent, true),
            (.healthyOwned, .healthyOwned, false),
            (.repairableOwned, .repairableOwned, true),
        ] {
            let decision = try AgentExactPreparation.decide(
                agent: agent, recordedTarget: nil,
                firstConnectResolvedTarget: URL(fileURLWithPath: snapshot.path),
                snapshot: snapshot, inspection: inspection
            )
            let request = try JSONDecoder().decode(ExactTargetPreparation.self, from: #require(decision.input))
            #expect(request.agent == agent)
            #expect(request.expectedState == expectedState)
            #expect(decision.changesVendorBytes == changes)
        }
    }
}

@Test func exactPreparationRefusesInvalidOrMismatchedSnapshots() throws {
    let snapshot = try absentSnapshot()
    let invalid = try AgentExactPreparation.decide(
        agent: .claude, recordedTarget: nil,
        firstConnectResolvedTarget: URL(fileURLWithPath: snapshot.path),
        snapshot: snapshot, inspection: .invalid
    )
    #expect(invalid.input == nil)
    #expect(throws: AgentExactPreparationError.self) {
        _ = try AgentExactPreparation.decide(
            agent: .claude, recordedTarget: nil,
            firstConnectResolvedTarget: URL(fileURLWithPath: "/tmp/other"),
            snapshot: snapshot, inspection: .absent
        )
    }
}

@Test func absentOpenCodeExactInspectionCreatesAFirstConnectRequest() throws {
    let target = URL(fileURLWithPath: "/tmp/absent-opencode/letitbrew.js")
    let snapshot = try absentSnapshot(target.path)
    let inspection = AgentExactDiskInspection.inspect(agent: .opencode, snapshot: snapshot, data: nil, helperPath: "/letitbrew")
    var launchedRequest: ExactTargetPreparation?
    let result = try AgentExactRefreshCoordinator.run(
        agent: .opencode, recordedTarget: nil, firstConnectResolvedTarget: target,
        inspect: { _ in .init(snapshot: inspection.snapshot, inspection: inspection.inspection) },
        launch: { _, data in
            launchedRequest = try? JSONDecoder().decode(ExactTargetPreparation.self, from: data)
            return false
        }
    )
    #expect(result.helperInvoked)
    #expect(launchedRequest?.expectedState == .absent)
}

@Test func helperFailureNeverReportsAChangeOrRestart() {
    #expect(!AgentExactPreparation.completion(changesVendorBytes: true, helperSucceeded: false).changedVendorBytes)
    #expect(AgentExactPreparation.completion(changesVendorBytes: true, helperSucceeded: true).shouldRestartSessions)
}
