import Testing
@testable import LetItBrewAppCore

@Test func actionPersistsAndRefreshesBeforeHelper() {
 var events:[String]=[]
 AgentConnectionActionCoordinator.perform(.connect,id:"opencode",selected:["claude"],persist:{ events.append("persist:\($0.sorted())") },refreshVisibility:{ events.append("refresh:\($0.sorted())") },launchHelper:{ _,id in events.append("helper:\(id)") })
 #expect(events == ["persist:[\"claude\", \"opencode\"]","refresh:[\"claude\", \"opencode\"]","helper:opencode"])
}

@Test func disconnectPersistsBeforeAFailedHelperAndUnknownHasNoEffect() {
    var events: [String] = []
    AgentConnectionActionCoordinator.perform(
        .disconnect, id: "codex", selected: ["claude", "codex"],
        persist: { events.append("persist:\($0.sorted())") },
        refreshVisibility: { events.append("refresh:\($0.sorted())") },
        launchHelper: { _, id in events.append("helper-failed:\(id)") }
    )
    AgentConnectionActionCoordinator.perform(
        .connect, id: "unknown", selected: ["claude"],
        persist: { _ in events.append("unexpected persist") },
        refreshVisibility: { _ in events.append("unexpected refresh") },
        launchHelper: { _, _ in events.append("unexpected helper") }
    )
    #expect(events == ["persist:[\"claude\"]", "refresh:[\"claude\"]", "helper-failed:codex"])
}

@Test func lateHelperFailureProducesDiagnosticWithoutRollingBackPersistedSelection() {
    var selected: Set<String> = ["claude"]
    var completion: ((AgentHelperOperationResult) -> AgentConnectionHelperCompletion)?
    AgentConnectionActionCoordinator.perform(
        .connect, id: "opencode", selected: selected,
        persist: { selected = $0 }, refreshVisibility: { _ in },
        launchHelper: { _, _ in
            completion = { result in
                AgentConnectionActionCoordinator.complete(
                    .connect, id: "opencode", selectedAgentIDs: selected, result: result
                )
            }
        }
    )
    #expect(selected == ["claude", "opencode"])
    let outcome = completion?(AgentHelperOperationResult(
        agentID: "opencode", status: 1, output: "helper refused", timedOut: false
    ))
    #expect(outcome?.state == .couldNotConnect)
    #expect(outcome?.details == ["helper refused"])
    #expect(outcome?.selectedAgentIDs == ["claude", "opencode"])
    // The live model consumes completion presentation only; it has no
    // persistence callback and therefore cannot undo the selection.
    #expect(selected == ["claude", "opencode"])
}
