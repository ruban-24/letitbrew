import Testing
@testable import LetItBrewCore

private func reduce(
    _ event: String,
    agent: AgentID = .claude,
    toolName: String? = nil,
    notificationType: String? = nil,
    source: String? = nil,
    trigger: String? = nil,
    hasBackgroundTasks: Bool = false,
    errorRecoverable: Bool? = nil
) -> HookEffect? {
    HookReducer.reduce(
        agent: agent,
        event: event,
        toolName: toolName,
        notificationType: notificationType,
        source: source,
        trigger: trigger,
        hasBackgroundTasks: hasBackgroundTasks,
        errorRecoverable: errorRecoverable
    )
}

@Test func onlyUnrecoverableCopilotErrorsBecomeIdle() {
    #expect(reduce("ErrorOccurred", errorRecoverable: false) == .set(.idle, detail: nil))
    #expect(reduce("ErrorOccurred", errorRecoverable: true) == nil)
    #expect(reduce("ErrorOccurred", errorRecoverable: nil) == nil)
}

@Test func sessionStartIsIdleNotWorking() {
    // A REPL opened and never prompted emits no further events. Marking it
    // working would hold the Mac awake for the life of the process.
    for source in ["startup", "resume", "clear"] {
        #expect(reduce("SessionStart", source: source) == .set(.idle, detail: nil))
    }
    #expect(reduce("SessionStart", agent: .codex) == .set(.idle, detail: nil))
}

@Test func claudeSessionStartFromAnUnknownSourceChangesNothing() {
    // A compaction restart, or a source Claude adds later, may fire inside a
    // running turn; releasing the hold there would let the Mac sleep mid-work.
    #expect(reduce("SessionStart") == nil)
    #expect(reduce("SessionStart", source: "some-future-source") == nil)
}

@Test func promptAndPostToolAreWorking() {
    #expect(reduce("UserPromptSubmit") == .set(.working, detail: nil))
    #expect(reduce("PostToolUse", toolName: "Bash") == .set(.working, detail: nil))
}

@Test func preToolUseCarriesADetailToken() {
    #expect(reduce("PreToolUse", toolName: "Bash")
        == .set(.working, detail: "running-command"))
    #expect(reduce("PreToolUse", toolName: "Edit")
        == .set(.working, detail: "editing-file"))
    #expect(reduce("PreToolUse", toolName: "Wibble")
        == .set(.working, detail: "tool:Wibble"))
    #expect(reduce("PreToolUse") == .set(.working, detail: nil))
}

@Test func permissionWaitEventsAreScopedToProvenPrompts() {
    let approval = HookEffect.set(.waiting, detail: SessionWaitDetail.approval)
    // Claude, Codex, and Copilot run PermissionRequest before another hook,
    // auto mode, an allow rule, or Codex's auto-reviewer decides, so it keeps
    // the prior state. Copilot's question tool still blocks on the person.
    #expect(reduce("PermissionRequest", agent: .claude) == nil)
    #expect(reduce("PermissionRequest", agent: .codex) == nil)
    #expect(reduce("PermissionRequest", agent: .copilot) == nil)
    #expect(reduce("PermissionRequest", agent: .copilot, toolName: "shell") == nil)
    #expect(reduce("PermissionRequest", agent: .copilot, toolName: "ask_user")
        == .set(.waiting, detail: SessionWaitDetail.question))
    #expect(reduce("PermissionRequest", agent: .opencode) == approval)
    #expect(reduce("PermissionRequest", agent: .pi) == nil)

    // Claude sends permission_prompt only for a prompt left on screen.
    #expect(reduce(
        "Notification", agent: .claude, notificationType: "permission_prompt"
    ) == approval)
    #expect(reduce(
        "Notification", agent: .claude, notificationType: "elicitation_dialog"
    ) == nil)
    #expect(reduce(
        "Notification", agent: .codex, notificationType: "permission_prompt"
    ) == nil)
    #expect(reduce(
        "Notification", agent: .copilot, notificationType: "permission_prompt"
    ) == approval)
    #expect(reduce(
        "Notification", agent: .copilot, notificationType: "elicitation_dialog"
    ) == approval)
}

@Test func questionToolsWaitOnlyForTheirOwnAgent() {
    let question = HookEffect.set(.waiting, detail: SessionWaitDetail.question)
    for toolName in ["ask_user", "ask_user_question", "AskUserQuestion"] {
        #expect(reduce("PreToolUse", agent: .copilot, toolName: toolName) == question)
    }
    #expect(reduce("PreToolUse", agent: .claude, toolName: "AskUserQuestion") == question)
    #expect(reduce("PreToolUse", agent: .codex, toolName: "request_user_input") == question)

    for toolName in ["ask_user", "ask_user_question"] {
        #expect(reduce("PreToolUse", agent: .claude, toolName: toolName)
            == .set(.working, detail: "tool:\(toolName)"))
    }
    #expect(reduce("PreToolUse", agent: .codex, toolName: "AskUserQuestion")
        == .set(.working, detail: "tool:AskUserQuestion"))
    #expect(reduce("PreToolUse", agent: .claude, toolName: "request_user_input")
        == .set(.working, detail: "tool:request_user_input"))
    #expect(reduce("PreToolUse", agent: .copilot, toolName: "bash")
        == .set(.working, detail: "tool:bash"))
    // The answer's PostToolUse resumes the turn.
    #expect(reduce("PostToolUse", agent: .claude, toolName: "AskUserQuestion")
        == .set(.working, detail: nil))
}

@Test func onlyOpenCodeAndPiSyntheticInputEdgesChangeState() {
    let question = HookEffect.set(.waiting, detail: SessionWaitDetail.question)
    #expect(reduce("UserInputRequested", agent: .opencode) == question)
    #expect(reduce("UserInputRequested", agent: .pi) == question)
    #expect(reduce("UserInputResolved", agent: .opencode) == .set(.working, detail: nil))
    #expect(reduce("UserInputRequested", agent: .claude) == nil)
    #expect(reduce("UserInputResolved", agent: .codex) == nil)
}

@Test func onlyStructuralIdleEdgesBecomeIdle() {
    #expect(reduce("Notification", notificationType: "idle_prompt")
        == .set(.idle, detail: nil))
    #expect(reduce("Notification") == nil)
    #expect(reduce("Notification", notificationType: "future_type") == nil)
    #expect(reduce("Stop") == .set(.idle, detail: nil))
}

@Test func ordinaryStopIsIdleAndSessionEndDeletes() {
    #expect(reduce("SessionEnd") == .end)
}

@Test func unknownEventIsANoOp() {
    // Both tools add event names over time. A new one must change nothing.
    #expect(reduce("SomeFutureEvent") == nil)
    #expect(reduce("") == nil)
}

@Test func claudeCompactionKeepsTheExistingState() {
    // Claude also compacts at an idle prompt, and an aborted compact emits
    // PreCompact alone. Neither is followed by Stop.
    #expect(reduce("SessionStart", source: "compact") == nil)
    for trigger in [nil, "manual", "auto"] {
        #expect(reduce("PreCompact", trigger: trigger) == nil)
    }
    #expect(reduce("PostCompact") == nil)
    #expect(reduce("PostCompact", trigger: "auto") == nil)
}

@Test func claudeManualCompactCompletionIsIdle() {
    // A manual compact runs only at the idle prompt, so no turn is running.
    #expect(reduce("PostCompact", trigger: "manual") == .set(.idle, detail: nil))
}

@Test func codexCompactionKeepsTheExistingState() {
    #expect(reduce("SessionStart", agent: .codex, source: "compact") == nil)
    for trigger in [nil, "manual", "auto"] {
        #expect(reduce("PreCompact", agent: .codex, trigger: trigger) == nil)
        #expect(reduce("PostCompact", agent: .codex, trigger: trigger) == nil)
    }
}

@Test func codexInterruptEndsTheTurn() {
    #expect(reduce("Interrupt", agent: .codex) == .set(.idle, detail: nil))
    #expect(reduce("Interrupt") == nil)
}

@Test func subagentsFailuresAndBackgroundWorkStayTwoState() {
    #expect(reduce("SubagentStart") == .set(.working, detail: nil))
    #expect(reduce("SubagentStop") == .end)
    #expect(reduce("StopFailure") == .set(.idle, detail: nil))
    #expect(reduce("Stop", hasBackgroundTasks: true) == .set(.working, detail: nil))
    #expect(reduce("Stop", hasBackgroundTasks: false) == .set(.idle, detail: nil))
}

@Test func copilotToolFailureReturnsToWork() {
    // A failed or cancelled tool, including the question tool, resumes the turn.
    #expect(reduce("PostToolUseFailure", agent: .copilot) == .set(.working, detail: nil))
    #expect(reduce("PostToolUseFailure", agent: .claude) == nil)
    #expect(reduce("PostToolUseFailure", agent: .codex) == nil)
}
