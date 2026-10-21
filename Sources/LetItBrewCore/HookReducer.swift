import Foundation

/// What a session is doing right now.
public enum SessionState: String, Codable, Sendable, Equatable {
    case working
    /// Blocked on the person: a question or an approval prompt. The detail
    /// token says which. A wait releases the hold until local input suggests
    /// someone may have answered; see `WaitAnswerLatch`. Its stored value is
    /// not "waiting": pre-0.5 records used that name with other semantics and
    /// remain unsupported.
    case waiting = "awaiting_input"
    case idle

    /// Working and Waiting both sit inside a turn; only Idle has ended one.
    public var isInTurn: Bool {
        self != .idle
    }
}

/// Semantic detail tokens for a Waiting session. Never English prose.
public enum SessionWaitDetail {
    public static let question = "waiting-question"
    public static let approval = "waiting-approval"
}

/// The effect one hook event has on a session's record.
public enum HookEffect: Equatable, Sendable {
    /// Write the state, with an optional semantic detail token.
    case set(SessionState, detail: String?)
    /// The session is over: delete its record.
    case end
}

/// Maps one agent's lifecycle event to its effect on the session record.
/// Event names are not assumed to have identical semantics across agents.
public enum HookReducer {
    public static func reduce(
        agent: AgentID,
        event: String,
        toolName: String?,
        notificationType: String?,
        source: String? = nil,
        trigger: String? = nil,
        hasBackgroundTasks: Bool = false,
        errorRecoverable: Bool? = nil
    ) -> HookEffect? {
        switch event {
        case "SessionStart":
            // Idle, not working: a session that has never been prompted emits
            // no further events, so `working` here would hold the Mac awake
            // for as long as the process lives. Still writes a record, so the
            // session appears immediately.
            if agent == .claude {
                // Only these sources start at an idle prompt. A compaction
                // restart, or a source Claude adds later, may fire inside a
                // running turn and must not release its hold.
                return ["startup", "resume", "clear"].contains(source)
                    ? .set(.idle, detail: nil) : nil
            }
            // A compaction restart keeps its turn's state; see PreCompact.
            return source == "compact" ? nil : .set(.idle, detail: nil)
        case "PreCompact":
            // Claude and Codex also compact at an idle prompt (/compact, and
            // Claude's idle auto-compaction before the prompt cache expires),
            // and an aborted compact emits PreCompact alone. No Stop follows
            // either, so compaction keeps the state its turn already established.
            return nil
        case "PostCompact":
            // A manual Claude compact runs only at the idle prompt, so its
            // completion proves no turn is running, including one an interrupt
            // left Working. Auto compaction can run inside a turn.
            return agent == .claude && trigger == "manual" ? .set(.idle, detail: nil) : nil
        case "Interrupt":
            // Codex's only hook for an Esc-cancelled turn; no Stop follows it.
            return agent == .codex ? .set(.idle, detail: nil) : nil
        case "SubagentStart":
            return .set(.working, detail: nil)
        case "UserPromptSubmit", "PostToolUse":
            return .set(.working, detail: nil)
        case "PostToolUseFailure":
            // A failed or cancelled Copilot tool, including its question
            // tool, returns to the turn it interrupted.
            return agent == .copilot ? .set(.working, detail: nil) : nil
        case "PreToolUse":
            // The question tool blocks on the person until its PostToolUse.
            if isUserQuestionTool(agent: agent, toolName: toolName) {
                return .set(.waiting, detail: SessionWaitDetail.question)
            }
            return .set(.working, detail: toolName.map(detailToken(forTool:)))
        case "PermissionRequest":
            // Claude, Codex, and Copilot run this hook before another hook,
            // auto mode, an allow rule, or Codex's auto-reviewer decides, so it
            // does not prove a person is being asked. Their approvals keep the
            // prior state; Copilot's question tool still blocks on the person.
            // OpenCode reports it only when it asks.
            if agent == .copilot, isUserQuestionTool(agent: agent, toolName: toolName) {
                return .set(.waiting, detail: SessionWaitDetail.question)
            }
            return agent == .opencode
                ? .set(.waiting, detail: SessionWaitDetail.approval)
                : nil
        case "Notification":
            if notificationType == "idle_prompt" {
                return .set(.idle, detail: nil)
            }
            // Claude sends permission_prompt only after its prompt has waited
            // on screen for about six seconds; a hook or classifier decision
            // made sooner never sends it.
            if agent == .claude, notificationType == "permission_prompt" {
                return .set(.waiting, detail: SessionWaitDetail.approval)
            }
            if agent == .copilot,
               ["permission_prompt", "elicitation_dialog"].contains(notificationType) {
                return .set(.waiting, detail: SessionWaitDetail.approval)
            }
            return nil
        case "UserInputRequested":
            return agent == .opencode || agent == .pi
                ? .set(.waiting, detail: SessionWaitDetail.question)
                : nil
        case "UserInputResolved":
            return agent == .opencode || agent == .pi ? .set(.working, detail: nil) : nil
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

    private static func isUserQuestionTool(agent: AgentID, toolName: String?) -> Bool {
        switch (agent, toolName) {
        case (.copilot, "ask_user"), (.copilot, "ask_user_question"),
             (.copilot, "AskUserQuestion"),
             (.claude, "AskUserQuestion"),
             (.codex, "request_user_input"):
            true
        default:
            false
        }
    }

}
