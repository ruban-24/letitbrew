import Testing
@testable import LetItBrewCore

@Test func supportedAgentCatalogIsExactAndStable() {
    #expect(AgentID.allCases.map(\.rawValue) == [
        "claude", "codex", "cursor", "opencode", "copilot",
    ])
    #expect(AgentID.allCases.map(\.displayName) == [
        "Claude Code", "Codex", "Cursor", "OpenCode", "GitHub Copilot CLI",
    ])
}
