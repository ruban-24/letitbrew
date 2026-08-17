import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func launchSnapshot(_ id: String) -> ExactFileSnapshot { try! ExactFileSnapshot(path: "/A/\(id)", exists: false) }

@Test func launchPresentationCoversSelectedAndUnselectedFiveAgentRows() {
    let inspections = AgentID.allCases.map { AgentConnectionInspection(agentID: $0.rawValue, state: $0 == .opencode ? .invalid : .healthyOwned, hasRecordedTarget: true, exactTargetSnapshot: launchSnapshot($0.rawValue)) }
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: inspections, selectedAgentIDs: ["claude", "codex"], outcomes: ["codex": .succeeded(changedVendorBytes: true)])
    #expect(rows.first(where: { $0.agentID == "claude" })?.state == .connected)
    #expect(rows.first(where: { $0.agentID == "codex" })?.state == .connected)
    for id in ["cursor", "opencode", "copilot"] {
        #expect(rows.first(where: { $0.agentID == id })?.disposition == .intentionallyDisconnected)
    }
}

@Test func exactRefusalAttemptsOnlyOriginalAAndNeverTouchesAmbientB() {
    let a = launchSnapshot("claude")
    let decision = AgentLaunchConnectionDecision(selectedAgentIDs: ["claude"], preparations: [.exactTarget(agentID: "claude", expectedState: .absent, snapshot: a)])
    var launches: [ExactTargetPreparation] = []
    let ambientB = Data("foreign B".utf8)
    let outcomes = AgentLaunchOutcomeCoordinator.execute(decision.preparations, runRecorded: { _ in .failed("unexpected") }, runExact: { request in
        launches.append(request)
        // Simulate a component replacement/refusal.  No resolver or helper
        // receives B, so the sentinel remains byte-identical.
        return .failed("snapshot changed at A")
    })
    #expect(launches == [try! ExactTargetPreparation(agent: .claude, snapshot: a, expectedState: .absent)])
    #expect(ambientB == Data("foreign B".utf8))
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: [.init(agentID: "claude", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: a)], selectedAgentIDs: ["claude"], outcomes: outcomes)
    #expect(rows.first?.state == .actionNeeded)
}
