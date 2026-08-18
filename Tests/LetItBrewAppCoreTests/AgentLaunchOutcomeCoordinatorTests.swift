import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func launchSnapshot(_ id: String) -> ExactFileSnapshot { try! ExactFileSnapshot(path: "/A/\(id)", exists: false) }

@Test func launchPresentationCoversSelectedAndUnselectedFourAgentRows() {
    let inspections = AgentID.allCases.map { AgentConnectionInspection(agentID: $0.rawValue, state: $0 == .opencode ? .invalid : .healthyOwned, hasRecordedTarget: true, exactTargetSnapshot: launchSnapshot($0.rawValue)) }
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: inspections, selectedAgentIDs: ["claude", "codex"], outcomes: ["codex": .succeeded(changedVendorBytes: true)], codexTrust: .trusted)
    #expect(rows.first(where: { $0.agentID == "claude" })?.state == .connected)
    #expect(rows.first(where: { $0.agentID == "codex" })?.state == .connected)
    for id in ["opencode", "copilot"] {
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
    let inspections = agents.map { AgentConnectionInspection(agentID: $0.rawValue, state: $0 == .opencode ? .invalid : ($0 == .copilot ? .absent : .repairableOwned), hasRecordedTarget: false, exactTargetSnapshot: launchSnapshot($0.rawValue)) }
    let outcomes = Dictionary(uniqueKeysWithValues: agents.map { ($0.rawValue, AgentLaunchHelperOutcome.succeeded(changedVendorBytes: true)) })
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: inspections, selectedAgentIDs: Set(agents.map(\.rawValue)), outcomes: outcomes, codexTrust: .trusted)
    #expect(rows.first(where: { $0.agentID == "opencode" })?.state == .actionNeeded)
    #expect(rows.first(where: { $0.agentID == "copilot" })?.details == ["Restart sessions that were already open."])
}

@Test func exactRefusalUsesDescriptorBoundaryAndPreservesForeignReplacementB() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let component = root.appendingPathComponent("component")
    let aURL = component.appendingPathComponent("A.json")
    try! FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try! Data("{}".utf8).write(to: aURL)
    let anchor = try! DirectoryAnchor.openNoFollow(at: root)
    let exactTarget = try! anchor.target(atAbsoluteURL: aURL)
    let captured = try! exactTarget.capture()

    // Swap the lexical component after A's retained descriptor captured its
    // identity.  The new A name is an unrelated foreign B inode.
    let original = root.appendingPathComponent("original-component")
    try! FileManager.default.moveItem(at: component, to: original)
    try! FileManager.default.createDirectory(at: component, withIntermediateDirectories: true)
    let bURL = component.appendingPathComponent("A.json")
    try! Data("foreign B".utf8).write(to: bURL)
    try! FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: bURL.path)
    let bBefore = try! Data(contentsOf: bURL)
    let bAttributes = try! FileManager.default.attributesOfItem(atPath: bURL.path)
    let decision = AgentLaunchConnectionDecision(selectedAgentIDs: ["claude"], preparations: [.exactTarget(agentID: "claude", expectedState: .repairableOwned, snapshot: captured.snapshot)])
    var launches: [ExactTargetPreparation] = []
    var recordedLaunches = 0
    let outcomes = AgentLaunchOutcomeCoordinator.execute(decision.preparations, runRecorded: { _ in recordedLaunches += 1; return .failed("unexpected") }, runExact: { request in
        launches.append(request)
        do {
            _ = try AtomicFile.write(Data("{\"patched\":true}".utf8), replacing: captured)
            return .succeeded(changedVendorBytes: true)
        } catch {
            return .failed("\(error)")
        }
    })
    #expect(recordedLaunches == 0)
    #expect(launches == [try! ExactTargetPreparation(agent: .claude, snapshot: captured.snapshot, expectedState: .repairableOwned)])
    #expect({ if case .failed = outcomes["claude"] { return true }; return false }())
    #expect(try! Data(contentsOf: bURL) == bBefore)
    let bAfter = try! FileManager.default.attributesOfItem(atPath: bURL.path)
    for key in [.posixPermissions, .modificationDate, .systemNumber, .systemFileNumber] as [FileAttributeKey] {
        #expect(bAfter[key] as? NSObject == bAttributes[key] as? NSObject)
    }
    let rows = AgentLaunchOutcomeCoordinator.present(inspections: [.init(agentID: "claude", state: .repairableOwned, hasRecordedTarget: false, exactTargetSnapshot: captured.snapshot)], selectedAgentIDs: ["claude"], outcomes: outcomes)
    #expect(rows.first?.state == .actionNeeded)
}
