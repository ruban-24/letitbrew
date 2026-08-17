import Foundation
import Testing
@testable import LetItBrewCore

@Test func claudeAndCodexCommandsCarryExplicitAgentIdentity() throws {
    let claude = try ClaudeHooks.hookCommand(event: "Stop", cliPath: "/opt/letitbrew")
    let codex = try CodexHooks.hookCommand(event: "Stop", cliPath: "/opt/letitbrew")
    #expect(claude.contains("hook claude Stop"))
    #expect(codex.contains("hook codex Stop"))
    #expect(claude.contains(">/dev/null 2>&1"))
    #expect(codex.contains(">/dev/null 2>&1"))
    #expect(claude.hasSuffix(HookFile.ownershipComment(marker: ClaudeHooks.marker)))
    #expect(codex.hasSuffix(HookFile.ownershipComment(marker: CodexHooks.marker)))
}

@Test func currentClaudeAndCodexLifecycleEventsAreInstalled() {
    #expect(Set(["PreCompact", "PostCompact", "SubagentStart", "SubagentStop", "StopFailure"])
        .isSubset(of: Set(ClaudeHooks.events)))
    #expect(Set(["PreCompact", "PostCompact", "SubagentStart", "SubagentStop"])
        .isSubset(of: Set(CodexHooks.events)))
    #expect(!CodexHooks.events.contains("StopFailure"))
}
