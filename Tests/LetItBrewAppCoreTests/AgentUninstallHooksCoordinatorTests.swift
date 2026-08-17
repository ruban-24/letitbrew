import Testing
@testable import LetItBrewAppCore

@Test func uninstallClearsSelectionAndVisibilityBeforeAllFiveRemovalAttempts() {
    var events: [String] = []
    var selected: Set<String> = ["claude", "codex"]
    AgentUninstallHooksCoordinator.perform(
        selected: selected,
        persist: { selected = $0; events.append("persist:\($0.sorted())") },
        refreshVisibility: { events.append("refresh:\($0.sorted())") },
        launchRemoval: { events.append("remove:\($0.sorted())") }
    )
    #expect(selected.isEmpty)
    #expect(events == ["persist:[]", "refresh:[]", "remove:[\"claude\", \"codex\", \"copilot\", \"cursor\", \"opencode\"]"])
}
