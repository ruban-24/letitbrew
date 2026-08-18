import Testing
@testable import LetItBrewAppCore
@testable import LetItBrewCore

@Test func uninstallClearsSelectionAndVisibilityBeforeAllFourRemovalAttempts() {
    var events: [String] = []
    var selected: Set<String> = ["claude", "codex"]
    AgentUninstallHooksCoordinator.perform(
        selected: selected,
        persist: { selected = $0; events.append("persist:\($0.sorted())") },
        refreshVisibility: { events.append("refresh:\($0.sorted())") },
        launchRemoval: { events.append("remove:\($0.sorted())") }
    )
    #expect(selected.isEmpty)
    #expect(events == ["persist:[]", "refresh:[]", "remove:[\"claude\", \"codex\", \"copilot\", \"opencode\"]"])
}

@Test func uninstallCompletionKeepsSelectionEmptyAndProvidesExactFailureRetry() {
    let failed = AgentHelperOperationResult(agentID: "copilot", status: 1, output: "permission denied", timedOut: false)
    let results = AgentID.allCases.map { agent in
        agent == .copilot ? failed : AgentHelperOperationResult(agentID: agent.rawValue, status: 0, output: "", timedOut: false)
    }
    let completion = AgentUninstallHooksCoordinator.complete(results)
    #expect(completion.selectedAgentIDs.isEmpty)
    #expect(completion.retryAgentIDs == ["copilot"])
    #expect(completion.rows.count == AgentID.allCases.count)
    let copilot = completion.rows.first { $0.agentID == "copilot" }
    #expect(copilot?.state == .couldNotConnect)
    #expect(copilot?.details.first == "permission denied")
    #expect(copilot?.disposition == .disconnectFailed)
    for agent in AgentID.allCases where agent != .copilot {
        #expect(completion.rows.first { $0.agentID == agent.rawValue }?.disposition == .intentionallyDisconnected)
    }
}

@Test func uninstallCompletionUsesEveryDisplayNameAndRetryNeverReinstallsSelection() {
    for failedAgent in AgentID.allCases {
        let failed = AgentHelperOperationResult(agentID: failedAgent.rawValue, status: 1, output: "", timedOut: false)
        let first = AgentUninstallHooksCoordinator.complete(
            AgentID.allCases.map { $0 == failedAgent ? failed : .init(agentID: $0.rawValue, status: 0, output: "", timedOut: false) }
        )
        #expect(first.selectedAgentIDs.isEmpty)
        #expect(first.retryAgentIDs == [failedAgent.rawValue])
        #expect(first.rows.first { $0.agentID == failedAgent.rawValue }?.details.first?.contains(failedAgent.displayName) == true)

        let retry = AgentUninstallHooksCoordinator.complete(
            AgentID.allCases.map { .init(agentID: $0.rawValue, status: 0, output: "", timedOut: false) }
        )
        #expect(retry.selectedAgentIDs.isEmpty)
        #expect(retry.retryAgentIDs.isEmpty)
        #expect(retry.rows.allSatisfy { $0.disposition == .intentionallyDisconnected })
    }
}

@Test func asyncUninstallCycleRunsAllFourThenOnlyFailuresAndFreshCycleResetsToAllFour() {
    var events: [String] = []
    var retained: (([AgentHelperOperationResult]) -> Void)?
    var cycle = AgentUninstallCycle()
    func run(_ ids: Set<String>) {
        AgentUninstallHooksCoordinator.performAsync(
            selected: ["claude"],
            persist: { events.append("persist:\($0.sorted())") },
            refreshVisibility: { events.append("refresh:\($0.sorted())") },
            launchRemoval: { _, callback in
                events.append("remove:\(ids.sorted())")
                retained = callback
            },
            handleCompletion: { cycle.record($0) }
        )
    }

    run(cycle.beginFresh())
    #expect(events == ["persist:[]", "refresh:[]", "remove:[\"claude\", \"codex\", \"copilot\", \"opencode\"]"])
    retained?(AgentID.allCases.map { agent in
        .init(agentID: agent.rawValue, status: agent == .opencode ? 1 : 0, output: "", timedOut: false)
    })
    #expect(cycle.failedAgentIDs == ["opencode"])

    run(cycle.beginRetry())
    #expect(events.suffix(3) == ["persist:[]", "refresh:[]", "remove:[\"opencode\"]"])
    retained?([.init(agentID: "opencode", status: 0, output: "", timedOut: false)])
    #expect(cycle.failedAgentIDs.isEmpty)
    // Every async removal runs the real empty-selection refresh first; the
    // coordinator has no install launch parameter or positive selection.
    #expect(events.filter { $0 == "refresh:[]" }.count == 2)

    cycle.beginPositiveIntent()
    run(cycle.beginFresh())
    #expect(events.suffix(3) == ["persist:[]", "refresh:[]", "remove:[\"claude\", \"codex\", \"copilot\", \"opencode\"]"])
}
