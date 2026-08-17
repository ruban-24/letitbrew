import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func fixtureSnapshot(_ path: String) -> ExactFileSnapshot { try! ExactFileSnapshot(path: path, exists: true, deviceID: 1, inode: 2, byteCount: 3, modificationSeconds: 4, modificationNanoseconds: 5, sha256: String(repeating: "a", count: 64)) }
private func fixtureAbsentSnapshot(_ path: String) -> ExactFileSnapshot { try! ExactFileSnapshot(path: path, exists: false) }

@Test func firstV06MigrationSelectsOnlyPreviouslyOwnedConnections() {
    let claude = fixtureSnapshot("/legacy/claude/settings.json")
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: nil, legacyDisconnected: ["codex"], inspections: [
        .init(agentID: "claude", state: .repairableOwned, hasRecordedTarget: false, exactTargetSnapshot: claude),
        .init(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: fixtureSnapshot("/legacy/codex/hooks.json")),
        .init(agentID: "cursor", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: fixtureAbsentSnapshot("/legacy/cursor"))], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs == ["claude"])
    #expect(decision.preparations == [.exactTarget(agentID: "claude", expectedState: .repairableOwned, snapshot: claude)])
}

@Test func persistedEmptySelectionNeverAutoConnectsAnything() {
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: [], legacyDisconnected: [], inspections: [.init(agentID: "claude", state: .repairableOwned, hasRecordedTarget: true, exactTargetSnapshot: nil)], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs.isEmpty); #expect(decision.preparations.isEmpty)
}

@Test func persistedSelectionRepairsAbsenceButNeverMutatesInvalidConfig() {
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: ["cursor", "copilot"], legacyDisconnected: [], inspections: [.init(agentID: "cursor", state: .absent, hasRecordedTarget: true, exactTargetSnapshot: nil), .init(agentID: "copilot", state: .invalid, hasRecordedTarget: true, exactTargetSnapshot: nil)], legacyMigratableAgentIDs: [])
    #expect(decision.selectedAgentIDs == ["cursor", "copilot"]); #expect(decision.preparations == [.recordedTarget(agentID: "cursor")])
}

@Test func selectedHealthyLegacyConnectionBackfillsItsExactTarget() {
    let snapshot = fixtureSnapshot("/legacy/codex/hooks.json")
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: nil, legacyDisconnected: [], inspections: [.init(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: snapshot)], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs == ["codex"])
    #expect(decision.preparations == [.exactTarget(agentID: "codex", expectedState: .healthyOwned, snapshot: snapshot)])
}

@Test func selectionAddsAndRemovesOnlyRequestedAgent() {
    #expect(AgentConnectionSelectionPolicy.selecting("cursor", in: ["claude"]) == ["claude", "cursor"])
    #expect(AgentConnectionSelectionPolicy.deselecting("cursor", from: ["claude", "cursor"]) == ["claude"])
}
