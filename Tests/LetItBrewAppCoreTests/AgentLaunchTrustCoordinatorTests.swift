import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func trustInspection(_ id: AgentID, target: URL) -> AgentConnectionInspection {
    .init(agentID: id.rawValue, state: .healthyOwned, hasRecordedTarget: true, exactTargetSnapshot: nil, selectedTarget: target)
}

@Test func launchTrustCallsOnlySelectedCodexWithItsOriginalTarget() {
    let codexA = URL(fileURLWithPath: "/recorded/A/hooks.json")
    let ambientB = URL(fileURLWithPath: "/ambient/B/hooks.json")
    let inspections = [trustInspection(.codex, target: codexA), trustInspection(.claude, target: ambientB)]
    for selected in [Set<String>(), ["claude"]] {
        var calls: [URL] = []
        let result = AgentLaunchTrustCoordinator.selectedCodexTrust(
            selectedAgentIDs: selected, inspections: inspections,
            inspect: { calls.append($0); return .trusted }
        )
        #expect(result == nil)
        #expect(calls.isEmpty)
    }
    var calls: [URL] = []
    let result = AgentLaunchTrustCoordinator.selectedCodexTrust(
        selectedAgentIDs: ["codex"], inspections: inspections,
        inspect: { calls.append($0); return .approvalRequired }
    )
    #expect(result == .approvalRequired)
    #expect(calls == [codexA])
}

@Test func selectedCodexWithoutTrustEvidenceIsActionable() {
    let inspection = trustInspection(.codex, target: URL(fileURLWithPath: "/recorded/A/hooks.json"))
    let row = AgentLaunchOutcomeCoordinator.present(
        inspections: [inspection], selectedAgentIDs: ["codex"],
        outcomes: [:]
    )[1]
    #expect(row.state == .couldNotConnect)
    #expect(row.details == ["Let It Brew could not verify Codex hook approval."])
}
