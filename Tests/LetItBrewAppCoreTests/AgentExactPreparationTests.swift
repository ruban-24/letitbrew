import Foundation
import Testing
@testable import LetItBrewAppCore
import LetItBrewCore

private func absentSnapshot(_ path: String = "/tmp/exact-target") throws -> ExactFileSnapshot { try ExactFileSnapshot(path: path, exists: false) }
@Test func exactPreparationEncodesEveryAgent() throws {
    for agent in AgentID.allCases {
        let snapshot = try absentSnapshot("/tmp/\(agent.rawValue)")
        let decision = try AgentExactPreparation.decide(agent: agent, recordedTarget: nil, configuredTarget: URL(fileURLWithPath: snapshot.path), firstConnectResolvedTarget: URL(fileURLWithPath: snapshot.path), snapshot: snapshot, inspection: .absent)
        #expect(try JSONDecoder().decode(ExactTargetPreparation.self, from: #require(decision.input)).agent == agent)
        #expect(decision.changesVendorBytes)
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
@Test func firstConnectUsesResolvedJSONTarget() throws {
    let snapshot = try absentSnapshot("/tmp/final"); let d = try AgentExactPreparation.decide(agent: .cursor, recordedTarget: nil, configuredTarget: URL(fileURLWithPath: "/tmp/link"), firstConnectResolvedTarget: URL(fileURLWithPath: "/tmp/final"), snapshot: snapshot, inspection: .repairableOwned)
    #expect(d.target.path == "/tmp/final"); #expect(d.changesVendorBytes)
}
