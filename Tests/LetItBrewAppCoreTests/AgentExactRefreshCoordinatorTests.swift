import Foundation
import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

private func refreshSnapshot(_ path: String) throws -> ExactFileSnapshot {
    try ExactFileSnapshot(path: path, exists: false)
}

@Test func exactRefreshUsesRecordedTargetForEveryAgentRequestAndPostInspection() throws {
    for agent in AgentID.allCases {
        let a = URL(fileURLWithPath: "/tmp/recorded-\(agent.rawValue)-A")
        let b = URL(fileURLWithPath: "/tmp/malformed-ambient-\(agent.rawValue)-B")
        let snapshot = try refreshSnapshot(a.path)
        var inspected: [URL] = []
        var stdin: Data?
        let result = try AgentExactRefreshCoordinator.run(
            agent: agent, recordedTarget: a.path, configuredTarget: b, firstConnectResolvedTarget: b,
            inspect: { target in
                inspected.append(target)
                #expect(target == a)
                return .init(snapshot: snapshot, inspection: .healthyOwned)
            },
            launch: { launchedAgent, input in
                #expect(launchedAgent == agent)
                stdin = input
                return true
            }
        )
        let request = try JSONDecoder().decode(ExactTargetPreparation.self, from: #require(stdin))
        #expect(request.agent == agent)
        #expect(request.snapshot.path == a.path)
        #expect(inspected == [a, a])
        #expect(result.target == a)
        #expect(result.helperInvoked && result.helperSucceeded)
        #expect(!result.completion.changedVendorBytes)
        #expect(!result.completion.shouldRestartSessions)
    }
}

@Test func exactRefreshMigratesUnrecordedHealthyResolvedJSONTargetWithoutRestart() throws {
    let configured = URL(fileURLWithPath: "/tmp/json-link-B")
    let final = URL(fileURLWithPath: "/tmp/json-final-C")
    let snapshot = try refreshSnapshot(final.path)
    var inspected: [URL] = []
    var input: Data?
    let result = try AgentExactRefreshCoordinator.run(
        agent: .claude, recordedTarget: nil, configuredTarget: configured, firstConnectResolvedTarget: final,
        inspect: { target in
            inspected.append(target)
            return .init(snapshot: snapshot, inspection: .healthyOwned)
        },
        launch: { _, request in input = request; return true }
    )
    #expect(inspected == [final, final])
    #expect(try JSONDecoder().decode(ExactTargetPreparation.self, from: #require(input)).snapshot.path == final.path)
    #expect(!result.completion.changedVendorBytes)
    #expect(!result.completion.shouldRestartSessions)
}

@Test func exactRefreshRefusesInvalidInspectionWithoutLaunchingHelper() throws {
    let target = URL(fileURLWithPath: "/tmp/invalid-A")
    let snapshot = try refreshSnapshot(target.path)
    var launched = false
    let result = try AgentExactRefreshCoordinator.run(
        agent: .codex, recordedTarget: target.path, configuredTarget: URL(fileURLWithPath: "/tmp/B"), firstConnectResolvedTarget: target,
        inspect: { _ in .init(snapshot: snapshot, inspection: .invalid) },
        launch: { _, _ in launched = true; return true }
    )
    #expect(!launched)
    #expect(!result.helperInvoked)
    #expect(result.request == nil)
}

@Test func exactRefreshUsesSameTargetForAbsentRepairAndHelperFailure() throws {
    let target = URL(fileURLWithPath: "/tmp/target-A")
    let snapshot = try refreshSnapshot(target.path)
    for (state, expectedChange) in [(AgentExactPreparation.Inspection.absent, true), (.repairableOwned, true)] {
        var inspected: [URL] = []
        let result = try AgentExactRefreshCoordinator.run(
            agent: .copilot, recordedTarget: target.path, configuredTarget: URL(fileURLWithPath: "/tmp/B"), firstConnectResolvedTarget: target,
            inspect: { value in inspected.append(value); return .init(snapshot: snapshot, inspection: state) },
            launch: { _, _ in true }
        )
        #expect(inspected == [target, target])
        #expect(result.completion.changedVendorBytes == expectedChange)
        #expect(result.completion.shouldRestartSessions == expectedChange)
    }
    var inspections = 0
    let refused = try AgentExactRefreshCoordinator.run(
        agent: .opencode, recordedTarget: target.path, configuredTarget: URL(fileURLWithPath: "/tmp/B"), firstConnectResolvedTarget: target,
        inspect: { _ in inspections += 1; return .init(snapshot: snapshot, inspection: .repairableOwned) },
        launch: { _, _ in false }
    )
    #expect(inspections == 1)
    #expect(refused.helperInvoked && !refused.helperSucceeded)
    #expect(!refused.completion.changedVendorBytes)
    #expect(!refused.completion.shouldRestartSessions)
}

@Test func exactRefreshPresentationUsesRecordedCodexTargetAndRejectsFailedPostInspection() throws {
    let recorded = URL(fileURLWithPath: "/tmp/codex-recorded-A")
    let ambient = URL(fileURLWithPath: "/tmp/codex-ambient-B")
    let snapshot = try refreshSnapshot(recorded.path)
    let codex = try AgentExactRefreshCoordinator.run(
        agent: .codex, recordedTarget: recorded.path, configuredTarget: ambient, firstConnectResolvedTarget: ambient,
        inspect: { target in
            #expect(target == recorded)
            return .init(snapshot: snapshot, inspection: .healthyOwned)
        },
        launch: { agent, _ in #expect(agent == .codex); return true }
    )
    #expect(codex.target == recorded)
    #expect(AgentExactRefreshCoordinator.mayPresentConnected(codex))

    for agent in [AgentID.opencode, .copilot] {
        var calls = 0
        let result = try AgentExactRefreshCoordinator.run(
            agent: agent, recordedTarget: recorded.path, configuredTarget: ambient, firstConnectResolvedTarget: ambient,
            inspect: { target in
                calls += 1; #expect(target == recorded)
                return .init(snapshot: snapshot, inspection: calls == 1 ? .repairableOwned : .invalid)
            },
            launch: { launchedAgent, _ in #expect(launchedAgent == agent); return true }
        )
        #expect(result.helperSucceeded)
        #expect(result.final.inspection == .invalid)
        #expect(!AgentExactRefreshCoordinator.mayPresentConnected(result))
    }
}

@Test func productionPresentationBindsTrustAndRestartToExactFinalState() {
    let a = URL(fileURLWithPath: "/tmp/recorded-A"); let b = URL(fileURLWithPath: "/tmp/ambient-B")
    let codex = AgentExactRefreshCoordinator.presentation(agent: .codex, selectedTarget: a, helperSucceeded: true, finalInspection: .healthyOwned, changedVendorBytes: false)
    #expect(codex.trustTarget == a); #expect(codex.trustTarget != b); #expect(codex.isConnected); #expect(!codex.shouldRestartSessions)
    for agent in AgentID.allCases {
        let failed = AgentExactRefreshCoordinator.presentation(agent: agent, selectedTarget: a, helperSucceeded: true, finalInspection: .repairableOwned, changedVendorBytes: true)
        #expect(!failed.isConnected); #expect(!failed.shouldRestartSessions)
        let mutation = AgentExactRefreshCoordinator.presentation(agent: agent, selectedTarget: a, helperSucceeded: true, finalInspection: .healthyOwned, changedVendorBytes: true)
        #expect(mutation.isConnected); #expect(mutation.shouldRestartSessions)
        let helperFailure = AgentExactRefreshCoordinator.presentation(agent: agent, selectedTarget: a, helperSucceeded: false, finalInspection: .healthyOwned, changedVendorBytes: true)
        #expect(!helperFailure.isConnected); #expect(!helperFailure.shouldRestartSessions)
    }
}

@Test func presentationTableMakesFinalStateTheOnlyConnectionAuthority() {
    let target = URL(fileURLWithPath: "/tmp/A")
    for agent in AgentID.allCases {
        for state in [AgentExactPreparation.Inspection.healthyOwned, .repairableOwned, .absent, .invalid] {
            for helperSucceeded in [false, true] {
                for changed in [false, true] {
                    let presentation = AgentExactRefreshCoordinator.presentation(agent: agent, selectedTarget: target, helperSucceeded: helperSucceeded, finalInspection: state, changedVendorBytes: changed)
                    let connected = helperSucceeded && state == .healthyOwned
                    #expect(presentation.isConnected == connected)
                    #expect(presentation.shouldRestartSessions == (connected && changed))
                    #expect(presentation.changedVendorBytes == (connected && changed))
                    #expect(agent == .codex ? presentation.trustTarget == target : presentation.trustTarget == nil)
                }
            }
        }
    }
}
