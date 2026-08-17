public enum AgentID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case cursor
    case opencode
    case copilot

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot CLI"
        }
    }
}
