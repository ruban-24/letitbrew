import Foundation
import Testing
@testable import LetItBrewAppCore
import LetItBrewCore

private func absentSnapshot(_ path: String = "/tmp/exact-target") throws -> ExactFileSnapshot { try ExactFileSnapshot(path: path, exists: false) }
@Test func exactPreparationEncodesEveryAgentAndMutationState() throws {
    for agent in AgentID.allCases {
        let snapshot = try absentSnapshot("/tmp/\(agent.rawValue)")
        for (inspection, expectedState, changes) in [
            (AgentExactPreparation.Inspection.absent, ExactTargetExpectedState.absent, true),
            (.healthyOwned, .healthyOwned, false),
            (.repairableOwned, .repairableOwned, true),
        ] {
            let decision = try AgentExactPreparation.decide(agent: agent, recordedTarget: nil, configuredTarget: URL(fileURLWithPath: snapshot.path), firstConnectResolvedTarget: URL(fileURLWithPath: snapshot.path), snapshot: snapshot, inspection: inspection)
            let request = try JSONDecoder().decode(ExactTargetPreparation.self, from: #require(decision.input))
            #expect(request.agent == agent)
            #expect(request.expectedState == expectedState)
            #expect(decision.changesVendorBytes == changes)
        }
    }
}
@Test func invalidInspectionNeverCreatesAHelperRequest() throws {
    let snapshot = try absentSnapshot(); let d = try AgentExactPreparation.decide(agent: .claude, recordedTarget: nil, configuredTarget: URL(fileURLWithPath: snapshot.path), firstConnectResolvedTarget: URL(fileURLWithPath: snapshot.path), snapshot: snapshot, inspection: .invalid)
    #expect(d.input == nil); #expect(!d.changesVendorBytes)
}
@Test func recordedTargetWinsAmbientAndHealthyDoesNotRestart() throws {
    let snapshot = try absentSnapshot("/tmp/A"); let d = try AgentExactPreparation.decide(agent: .copilot, recordedTarget: "/tmp/A", configuredTarget: URL(fileURLWithPath: "/tmp/B"), firstConnectResolvedTarget: URL(fileURLWithPath: "/tmp/B"), snapshot: snapshot, inspection: .healthyOwned)
    #expect(d.target.path == "/tmp/A"); #expect(!d.changesVendorBytes)
}
@Test func recordedTargetWinsAmbientForCopilotAndOpenCode() throws {
    for agent in [AgentID.copilot, .opencode] {
        let snapshot = try absentSnapshot("/tmp/recorded-\(agent.rawValue)-A")
        let decision = try AgentExactPreparation.decide(
            agent: agent,
            recordedTarget: snapshot.path,
            configuredTarget: URL(fileURLWithPath: "/tmp/ambient-\(agent.rawValue)-B"),
            firstConnectResolvedTarget: URL(fileURLWithPath: "/tmp/ambient-\(agent.rawValue)-B"),
            snapshot: snapshot,
            inspection: .absent
        )
        #expect(decision.target.path == snapshot.path)
        #expect(try JSONDecoder().decode(ExactTargetPreparation.self, from: #require(decision.input)).snapshot.path == snapshot.path)
    }
}
@Test func firstConnectUsesResolvedJSONTarget() throws {
    let snapshot = try absentSnapshot("/tmp/final"); let d = try AgentExactPreparation.decide(agent: .cursor, recordedTarget: nil, configuredTarget: URL(fileURLWithPath: "/tmp/link"), firstConnectResolvedTarget: URL(fileURLWithPath: "/tmp/final"), snapshot: snapshot, inspection: .repairableOwned)
    #expect(d.target.path == "/tmp/final"); #expect(d.changesVendorBytes)
}
@Test func helperFailureNeverReportsAChangeOrRestart() {
    #expect(!AgentExactPreparation.completion(changesVendorBytes: true, helperSucceeded: false).changedVendorBytes)
    #expect(!AgentExactPreparation.completion(changesVendorBytes: true, helperSucceeded: false).shouldRestartSessions)
    #expect(!AgentExactPreparation.completion(changesVendorBytes: false, helperSucceeded: true).shouldRestartSessions)
    #expect(AgentExactPreparation.completion(changesVendorBytes: true, helperSucceeded: true).shouldRestartSessions)
}
