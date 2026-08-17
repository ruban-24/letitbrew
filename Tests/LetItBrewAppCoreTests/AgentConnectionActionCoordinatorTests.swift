import Testing
@testable import LetItBrewAppCore

@Test func actionPersistsAndRefreshesBeforeHelper() {
 var events:[String]=[]
 AgentConnectionActionCoordinator.perform(.connect,id:"cursor",selected:["claude"],persist:{ events.append("persist:\($0.sorted())") },refreshVisibility:{ events.append("refresh:\($0.sorted())") },launchHelper:{ _,id in events.append("helper:\(id)") })
 #expect(events == ["persist:[\"claude\", \"cursor\"]","refresh:[\"claude\", \"cursor\"]","helper:cursor"])
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
