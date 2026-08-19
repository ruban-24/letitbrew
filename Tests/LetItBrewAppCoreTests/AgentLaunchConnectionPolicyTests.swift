import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func policySnapshot(_ path: String, exists: Bool = true) -> ExactFileSnapshot {
    try! ExactFileSnapshot(path: path, exists: exists, deviceID: exists ? 1 : nil, inode: exists ? 2 : nil, byteCount: exists ? 3 : nil, modificationSeconds: exists ? 4 : nil, modificationNanoseconds: exists ? 5 : nil, sha256: exists ? String(repeating: "a", count: 64) : nil)
}

@Test func firstV06MigrationSelectsOnlyPreviouslyOwnedConnections() {
    let claude = policySnapshot("/legacy/claude/settings.json")
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: nil, legacyDisconnected: ["codex"], inspections: [
        .init(agentID: "claude", state: .repairableOwned, hasRecordedTarget: false, exactTargetSnapshot: claude),
        .init(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: policySnapshot("/legacy/codex/hooks.json")),
        .init(agentID: "opencode", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: policySnapshot("/legacy/opencode", exists: false)),
    ], legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(decision.selectedAgentIDs == ["claude"])
    #expect(decision.preparations == [.exactTarget(agentID: "claude", expectedState: .repairableOwned, snapshot: claude)])
}

@Test func authoritativeSelectionFiltersUnknownValuesAndNeverMutatesInvalidConfig() {
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: ["opencode", "copilot", "unknown"], legacyDisconnected: [], inspections: [
        .init(agentID: "opencode", state: .absent, hasRecordedTarget: true, exactTargetSnapshot: nil),
        .init(agentID: "copilot", state: .invalid, hasRecordedTarget: true, exactTargetSnapshot: nil),
    ], legacyMigratableAgentIDs: [])
    #expect(decision.selectedAgentIDs == ["opencode", "copilot"])
    #expect(decision.preparations == [.recordedTarget(agentID: "opencode")])
}

@Test func preparationsCoverRecordedAndExactStatesInSortedOrder() {
    let healthy = policySnapshot("/legacy/a")
    let absent = policySnapshot("/legacy/b", exists: false)
    let decision = AgentLaunchConnectionPolicy.decision(persistedSelection: ["opencode", "claude", "codex", "copilot"], legacyDisconnected: [], inspections: [
        .init(agentID: "opencode", state: .repairableOwned, hasRecordedTarget: true, exactTargetSnapshot: nil),
        .init(agentID: "claude", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: absent),
        .init(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: healthy),
        .init(agentID: "copilot", state: .invalid, hasRecordedTarget: true, exactTargetSnapshot: nil),
    ], legacyMigratableAgentIDs: [])
    #expect(decision.preparations == [
        .exactTarget(agentID: "claude", expectedState: .absent, snapshot: absent),
        .exactTarget(agentID: "codex", expectedState: .healthyOwned, snapshot: healthy),
        .recordedTarget(agentID: "opencode"),
    ])
}
