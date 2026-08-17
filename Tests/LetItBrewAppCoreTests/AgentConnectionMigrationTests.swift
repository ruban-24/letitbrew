import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func migrationSnapshot() -> ExactFileSnapshot {
    try! ExactFileSnapshot(path: "/migration/a", exists: false)
}

@Test func migrationConsultsLegacyOnlyWhenV2IsTrulyMissing() {
    let inspections = [AgentConnectionInspection(agentID: "claude", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: migrationSnapshot())]
    let missing = AgentConnectionMigration.migrate(persisted: .missing, legacyDisconnected: [], inspections: inspections, legacyMigratableAgentIDs: ["claude", "codex"])
    let empty = AgentConnectionMigration.migrate(persisted: .values([]), legacyDisconnected: [], inspections: inspections, legacyMigratableAgentIDs: ["claude", "codex"])
    let malformed = AgentConnectionMigration.migrate(persisted: .malformed, legacyDisconnected: [], inspections: inspections, legacyMigratableAgentIDs: ["claude", "codex"])
    #expect(missing.consultedLegacy)
    #expect(missing.decision.selectedAgentIDs == ["claude"])
    #expect(!empty.consultedLegacy && empty.decision.selectedAgentIDs.isEmpty)
    #expect(!malformed.consultedLegacy && malformed.decision.selectedAgentIDs.isEmpty)
}

@Test func migrationFiltersUnknownAuthoritativeValuesWithoutLegacyFallback() {
    let result = AgentConnectionMigration.migrate(
        persisted: .values(["cursor", "unknown"]), legacyDisconnected: [],
        inspections: [AgentConnectionInspection(agentID: "claude", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: migrationSnapshot())],
        legacyMigratableAgentIDs: ["claude", "codex"]
    )
    #expect(!result.consultedLegacy)
    #expect(result.decision.selectedAgentIDs == ["cursor"])
}
