import Foundation

/// What a session is doing right now.
public enum SessionState: String, Codable, Sendable, Equatable {
    case working
    case idle
}

/// The effect one hook event has on a session's record.
public enum HookEffect: Equatable, Sendable {
    /// Write the state, with an optional semantic detail token.
    case set(SessionState, detail: String?)
    /// The session is over: delete its record.
    case end
}

/// Maps a lifecycle hook event to its effect on the session record.
///
/// Claude Code and Codex share event names and payload semantics, so this
/// serves both. Codex simply never emits `Notification`.
public enum HookReducer {
    public static func reduce(
        event: String,
        toolName: String?,
        notificationType: String?,
        source: String? = nil,
        hasBackgroundTasks: Bool = false,
        errorRecoverable: Bool? = nil
    ) -> HookEffect? {
        switch event {
        case "SessionStart":
            // Idle, not working: a session that has never been prompted emits
            // no further events, so `working` here would hold the Mac awake
            // for as long as the process lives. Still writes a record, so the
            // session appears immediately.
            return source == "compact" ? .set(.working, detail: nil) : .set(.idle, detail: nil)
        case "PreCompact", "PostCompact", "SubagentStart":
            return .set(.working, detail: nil)
        case "UserPromptSubmit", "PostToolUse":
            return .set(.working, detail: nil)
        case "PreToolUse":
            return .set(.working, detail: toolName.map(detailToken(forTool:)))
        case "PermissionRequest":
            return nil
        case "Notification":
            return notificationType == "idle_prompt" ? .set(.idle, detail: nil) : nil
        case "Stop":
            return hasBackgroundTasks ? .set(.working, detail: nil) : .set(.idle, detail: nil)
        case "StopFailure":
            return .set(.idle, detail: nil)
        case "ErrorOccurred":
            // Copilot can recover from some execution errors and continue the
            // same turn. Only its explicit terminal value releases the hold;
            // a missing or future payload shape preserves the prior state.
            return errorRecoverable == false ? .set(.idle, detail: nil) : nil
        case "SubagentStop", "SessionEnd":
            return .end
        default:
            // Unknown events change nothing. Both tools add names over time.
            return nil
        }
    }

    /// Semantic token describing the running tool. Never English prose: the
    /// UI localizes these at render time. `tool:<name>` is the catch-all.
    static func detailToken(forTool tool: String) -> String {
        switch tool {
        case "Bash", "BashOutput", "KillShell": return "running-command"
        case "Edit", "Write", "NotebookEdit": return "editing-file"
        case "Read", "Glob", "Grep": return "reading-code"
        case "WebFetch", "WebSearch": return "searching-web"
        case "Task", "Agent": return "running-subagent"
        default: return "tool:\(tool)"
        }
    }

}
