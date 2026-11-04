import Testing
@testable import LetItBrewCore

@Test func supportedAgentCatalogIsExactAndStable() {
    #expect(AgentID.allCases.map(\.rawValue) == [
        "claude", "codex", "opencode", "copilot", "pi", "cursor", "gemini", "qwen", "kimi",
    ])
    #expect(AgentID.allCases.map(\.displayName) == [
        "Claude Code", "Codex", "OpenCode", "GitHub Copilot CLI", "Pi",
        "Cursor", "Gemini CLI", "Qwen Code", "Kimi Code",
    ])
}
