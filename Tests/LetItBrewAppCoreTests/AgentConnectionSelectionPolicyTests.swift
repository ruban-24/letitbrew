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
        .init(agentID: "opencode", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: fixtureAbsentSnapshot("/legacy/opencode"))], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs == ["claude"])
    #expect(decision.preparations == [.exactTarget(agentID: "claude", expectedState: .repairableOwned, snapshot: claude)])
}

@Test func persistedEmptySelectionNeverAutoConnectsAnything() {
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: [], legacyDisconnected: [], inspections: [.init(agentID: "claude", state: .repairableOwned, hasRecordedTarget: true, exactTargetSnapshot: nil)], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs.isEmpty); #expect(decision.preparations.isEmpty)
}

@Test func persistedSelectionRepairsAbsenceButNeverMutatesInvalidConfig() {
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: ["opencode", "copilot"], legacyDisconnected: [], inspections: [.init(agentID: "opencode", state: .absent, hasRecordedTarget: true, exactTargetSnapshot: nil), .init(agentID: "copilot", state: .invalid, hasRecordedTarget: true, exactTargetSnapshot: nil)], legacyMigratableAgentIDs: [])
    #expect(decision.selectedAgentIDs == ["opencode", "copilot"]); #expect(decision.preparations == [.recordedTarget(agentID: "opencode")])
}

@Test func selectedHealthyLegacyConnectionBackfillsItsExactTarget() {
    let snapshot = fixtureSnapshot("/legacy/codex/hooks.json")
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: nil, legacyDisconnected: [], inspections: [.init(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: snapshot)], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs == ["codex"])
    #expect(decision.preparations == [.exactTarget(agentID: "codex", expectedState: .healthyOwned, snapshot: snapshot)])
}

@Test func selectionAddsAndRemovesOnlyRequestedAgent() {
    #expect(AgentConnectionSelectionPolicy.selecting("opencode", in: ["claude"]) == ["claude", "opencode"])
    #expect(AgentConnectionSelectionPolicy.deselecting("opencode", from: ["claude", "opencode"]) == ["claude"])
}

@Test func selectionPolicyAdversarialMatrixIsDeterministic() {
    let snapshot = fixtureSnapshot("/legacy/a")
    let all = AgentID.allCases.map(\.rawValue)
    let inspections = all.map { AgentConnectionInspection(agentID: $0, state: .healthyOwned, hasRecordedTarget: true, exactTargetSnapshot: snapshot) }
    let persisted = AgentLaunchConnectionPolicy.decision(persistedSelection: ["codex", "unknown"], legacyDisconnected: ["codex"], inspections: inspections, legacyMigratableAgentIDs: ["claude"])
    #expect(persisted.selectedAgentIDs == ["codex"]); #expect(persisted.preparations.isEmpty)
    let legacy = AgentLaunchConnectionPolicy.decision(persistedSelection: nil, legacyDisconnected: [], inspections: inspections, legacyMigratableAgentIDs: Set(all + ["unknown"]))
    #expect(legacy.selectedAgentIDs == ["claude", "codex"])
    let duplicate = AgentLaunchConnectionPolicy.decision(persistedSelection: ["claude"], legacyDisconnected: [], inspections: [.init(agentID: "claude", state: .invalid, hasRecordedTarget: true, exactTargetSnapshot: nil), .init(agentID: "claude", state: .absent, hasRecordedTarget: true, exactTargetSnapshot: nil), .init(agentID: "unknown", state: .repairableOwned, hasRecordedTarget: false, exactTargetSnapshot: snapshot)], legacyMigratableAgentIDs: [])
    #expect(duplicate.selectedAgentIDs == ["claude"]); #expect(duplicate.preparations.isEmpty)
}

@Test func preparationsCoverRecordedAndExactStatesInSortedOrder() {
    let a = fixtureSnapshot("/legacy/a"); let b = fixtureAbsentSnapshot("/legacy/b")
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: ["opencode", "claude", "codex", "copilot"], legacyDisconnected: [], inspections: [
        .init(agentID: "opencode", state: .repairableOwned, hasRecordedTarget: true, exactTargetSnapshot: nil),
        .init(agentID: "claude", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: b),
        .init(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: a),
        .init(agentID: "copilot", state: .invalid, hasRecordedTarget: true, exactTargetSnapshot: nil)], legacyMigratableAgentIDs: [])
    #expect(decision.preparations == [.exactTarget(agentID: "claude", expectedState: .absent, snapshot: b), .exactTarget(agentID: "codex", expectedState: .healthyOwned, snapshot: a), .recordedTarget(agentID: "opencode")])
}
