import Testing
@testable import LetItBrewCore

private func reduce(
    _ event: String,
    source: String? = nil,
    hasBackgroundTasks: Bool = false,
    errorRecoverable: Bool? = nil
) -> HookEffect? {
    HookReducer.reduce(
        event: event,
        toolName: nil,
        notificationType: nil,
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
    #expect(HookReducer.reduce(event: "SessionStart", toolName: nil, notificationType: nil)
            == .set(.idle, detail: nil))
}

@Test func promptAndPostToolAreWorking() {
    #expect(HookReducer.reduce(event: "UserPromptSubmit", toolName: nil, notificationType: nil)
            == .set(.working, detail: nil))
    #expect(HookReducer.reduce(event: "PostToolUse", toolName: "Bash", notificationType: nil)
            == .set(.working, detail: nil))
}

@Test func preToolUseCarriesADetailToken() {
    #expect(HookReducer.reduce(event: "PreToolUse", toolName: "Bash", notificationType: nil)
            == .set(.working, detail: "running-command"))
    #expect(HookReducer.reduce(event: "PreToolUse", toolName: "Edit", notificationType: nil)
            == .set(.working, detail: "editing-file"))
    #expect(HookReducer.reduce(event: "PreToolUse", toolName: "Wibble", notificationType: nil)
            == .set(.working, detail: "tool:Wibble"))
    #expect(HookReducer.reduce(event: "PreToolUse", toolName: nil, notificationType: nil)
            == .set(.working, detail: nil))
}

@Test func permissionEventsPreservePriorState() {
    #expect(HookReducer.reduce(
        event: "PermissionRequest", toolName: nil, notificationType: nil
    ) == nil)
    #expect(HookReducer.reduce(
        event: "Notification", toolName: nil,
        notificationType: "permission_prompt"
    ) == nil)
}

@Test func onlyStructuralIdleEdgesBecomeIdle() {
    #expect(HookReducer.reduce(
        event: "Notification", toolName: nil,
        notificationType: "idle_prompt"
    ) == .set(.idle, detail: nil))
    #expect(HookReducer.reduce(
        event: "Notification", toolName: nil,
        notificationType: nil
    ) == nil)
    #expect(HookReducer.reduce(
        event: "Notification", toolName: nil,
        notificationType: "future_type"
    ) == nil)
    #expect(HookReducer.reduce(
        event: "Stop", toolName: nil, notificationType: nil
    ) == .set(.idle, detail: nil))
}

@Test func ordinaryStopIsIdleAndSessionEndDeletes() {
    #expect(HookReducer.reduce(event: "SessionEnd", toolName: nil, notificationType: nil) == .end)
}

@Test func unknownEventIsANoOp() {
    // Both tools add event names over time. A new one must change nothing.
    #expect(HookReducer.reduce(event: "SomeFutureEvent", toolName: nil, notificationType: nil) == nil)
    #expect(HookReducer.reduce(event: "", toolName: nil, notificationType: nil) == nil)
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
