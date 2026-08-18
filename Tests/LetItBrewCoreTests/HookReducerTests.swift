import Testing
@testable import LetItBrewCore

private func reduce(
    _ event: String,
    agent: AgentID = .claude,
    toolName: String? = nil,
    notificationType: String? = nil,
    source: String? = nil,
    hasBackgroundTasks: Bool = false,
    errorRecoverable: Bool? = nil
) -> HookEffect? {
    HookReducer.reduce(
        agent: agent,
        event: event,
        toolName: toolName,
        notificationType: notificationType,
        source: source,
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
    #expect(reduce("SessionStart") == .set(.idle, detail: nil))
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

@Test func permissionWaitEventsAreScopedToCopilotAndOpenCode() {
    #expect(reduce("PermissionRequest", agent: .claude) == nil)
    #expect(reduce("PermissionRequest", agent: .codex) == nil)
    #expect(reduce("PermissionRequest", agent: .copilot) == .set(.idle, detail: nil))
    #expect(reduce("PermissionRequest", agent: .opencode) == .set(.idle, detail: nil))

    #expect(reduce(
        "Notification", agent: .claude, notificationType: "permission_prompt"
    ) == nil)
    #expect(reduce(
        "Notification", agent: .copilot, notificationType: "permission_prompt"
    ) == .set(.idle, detail: nil))
    #expect(reduce(
        "Notification", agent: .copilot, notificationType: "elicitation_dialog"
    ) == .set(.idle, detail: nil))
}

@Test func onlyCopilotQuestionToolBecomesIdle() {
    for toolName in ["ask_user", "ask_user_question", "AskUserQuestion"] {
        #expect(reduce("PreToolUse", agent: .copilot, toolName: toolName)
            == .set(.idle, detail: nil))
        #expect(reduce("PreToolUse", agent: .claude, toolName: toolName)
            == .set(.working, detail: "tool:\(toolName)"))
    }
    #expect(reduce("PreToolUse", agent: .copilot, toolName: "bash")
        == .set(.working, detail: "tool:bash"))
}

@Test func onlyOpenCodeSyntheticInputEdgesChangeState() {
    #expect(reduce("UserInputRequested", agent: .opencode) == .set(.idle, detail: nil))
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

@Test func compactionSubagentsFailuresAndBackgroundWorkStayTwoState() {
    #expect(reduce("SessionStart", source: "compact") == .set(.working, detail: nil))
    #expect(reduce("PreCompact") == .set(.working, detail: nil))
    #expect(reduce("PostCompact") == .set(.working, detail: nil))
    #expect(reduce("SubagentStart") == .set(.working, detail: nil))
    #expect(reduce("SubagentStop") == .end)
    #expect(reduce("StopFailure") == .set(.idle, detail: nil))
    #expect(reduce("Stop", hasBackgroundTasks: true) == .set(.working, detail: nil))
    #expect(reduce("Stop", hasBackgroundTasks: false) == .set(.idle, detail: nil))
}
