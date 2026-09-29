public enum AgentID: String, CaseIterable, Codable, Sendable {
    case claude
    case codex
    case opencode
    case copilot
    case pi

    /// Owned executable adapters must never follow a same-name file symlink.
    public var ownsWholeConfigurationFile: Bool {
        self == .opencode || self == .pi
    }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .opencode: "OpenCode"
        case .copilot: "GitHub Copilot CLI"
        case .pi: "Pi"
        }
    }
}
