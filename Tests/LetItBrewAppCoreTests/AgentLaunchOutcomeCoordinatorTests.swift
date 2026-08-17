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

@Test func healthyExactSuccessDoesNotRestartAndCodexTrustControlsConnection() {
    let snapshot = launchSnapshot("codex")
    let inspection = AgentConnectionInspection(agentID: "codex", state: .healthyOwned, hasRecordedTarget: false, exactTargetSnapshot: snapshot, selectedTarget: URL(fileURLWithPath: "/recorded/codex.json"))
    for trust in [CodexHookTrustResult.trusted, .approvalRequired, .couldNotVerify] {
        let rows = AgentLaunchOutcomeCoordinator.present(inspections: [inspection], selectedAgentIDs: ["codex"], outcomes: ["codex": .succeeded(changedVendorBytes: false)], codexTrust: trust)
        let row = rows[1]
        switch trust {
        case .trusted: #expect(row.state == .connected && row.details.isEmpty)
        case .approvalRequired: #expect(row.state == .actionNeeded)
        case .couldNotVerify: #expect(row.state == .couldNotConnect)
        }
    }
}

@Test func selectedRepairAndAbsentRestartButInvalidAndFailuresAreActionable() {
    let agents = AgentID.allCases
    let inspections = agents.map { AgentConnectionInspection(agentID: $0.rawValue, state: $0 == .opencode ? .invalid : ($0 == .cursor ? .absent : .repairableOwned), hasRecordedTarget: false, exactTargetSnapshot: launchSnapshot($0.rawValue)) }
    let outcomes = Dictionary(uniqueKeysWithValues: agents.map { ($0.rawValue, AgentLaunchHelperOutcome.succeeded(changedVendorBytes: true)) })
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: inspections, selectedAgentIDs: Set(agents.map(\.rawValue)), outcomes: outcomes, codexTrust: .trusted)
    #expect(rows.first(where: { $0.agentID == "opencode" })?.state == .actionNeeded)
    #expect(rows.first(where: { $0.agentID == "cursor" })?.details == ["Restart sessions that were already open."])
}

@Test func exactRefusalAttemptsOnlyOriginalAAndNeverTouchesAmbientB() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("component")
    let aURL = component.appendingPathComponent("A.json")
    let bURL = root.appendingPathComponent("ambient-B.json")
    try! FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try! Data("A".utf8).write(to: aURL)
    try! Data("foreign B".utf8).write(to: bURL)
    let bBefore = try! Data(contentsOf: bURL)
    let bAttributes = try! FileManager.default.attributesOfItem(atPath: bURL.path)
    let a = try! ExactFileSnapshot.capture(at: aURL)
    let decision = AgentLaunchConnectionDecision(selectedAgentIDs: ["claude"], preparations: [.exactTarget(agentID: "claude", expectedState: .absent, snapshot: a)])
    var launches: [ExactTargetPreparation] = []
    // Swap a parent component after the immutable A evidence was captured.
    let replacement = root.appendingPathComponent("replacement")
    try! FileManager.default.moveItem(at: component, to: replacement)
    try! FileManager.default.createSymbolicLink(at: component, withDestinationURL: replacement)
    let outcomes = AgentLaunchOutcomeCoordinator.execute(decision.preparations, runRecorded: { _ in .failed("unexpected") }, runExact: { request in
        launches.append(request)
        // The exact helper refuses the original A evidence; no resolver or
        // fallback helper receives ambient B after the component swap.
        return .failed("snapshot changed at A")
    })
    #expect(launches == [try! ExactTargetPreparation(agent: .claude, snapshot: a, expectedState: .absent)])
    #expect(try! Data(contentsOf: bURL) == bBefore)
    #expect((try! FileManager.default.attributesOfItem(atPath: bURL.path))[.modificationDate] as? Date == bAttributes[.modificationDate] as? Date)
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: [.init(agentID: "claude", state: .absent, hasRecordedTarget: false, exactTargetSnapshot: a)], selectedAgentIDs: ["claude"], outcomes: outcomes)
    #expect(rows.first?.state == .actionNeeded)
}
