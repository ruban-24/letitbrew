import Testing
import Foundation
@testable import LetItBrewCore

@Test func decodesSnakeCaseFields() throws {
    let json = Data("""
    {"session_id":"abc","cwd":"/tmp/repo","hook_event_name":"Stop","tool_name":"Bash",
     "notification_type":"idle_prompt",
     "message":"private notification prose",
     "last_assistant_message":"private assistant prose"}
    """.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    #expect(payload.sessionId == "abc")
    #expect(payload.cwd == "/tmp/repo")
    #expect(payload.hookEventName == "Stop")
    #expect(payload.toolName == "Bash")
    #expect(payload.notificationType == "idle_prompt")
}

@Test func ignoresUnknownFieldsAndMissingFields() throws {
    let json = Data(#"{"session_id":"abc","brand_new_field":{"nested":1}}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: json)
    #expect(payload.sessionId == "abc")
    #expect(payload.toolName == nil)
    #expect(payload.notificationType == nil)
    #expect(payload.errorRecoverable == nil)
}

@Test func decodesCopilotErrorRecoverabilityWithoutReadingErrorProse() throws {
    let recoverable = try JSONDecoder().decode(
        HookPayload.self,
        from: Data(#"{"session_id":"copilot-1","recoverable":true,"error":{"message":"private"}}"#.utf8)
    )
    let terminal = try JSONDecoder().decode(
        HookPayload.self,
        from: Data(#"{"session_id":"copilot-2","recoverable":false,"error_context":"model_call"}"#.utf8)
    )
    #expect(recoverable.errorRecoverable == true)
    #expect(terminal.errorRecoverable == false)
}

@Test func decodesEmptyObject() throws {
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data("{}".utf8))
    #expect(payload.sessionId == nil)
}

@Test func snakeCaseIdentityWinsOverCamelCaseAlias() throws {
    let data = Data(#"{"session_id":"primary","sessionId":"camel"}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(payload.sessionId == "primary")
}

@Test func childIdentityAndCompactionSourceDecodeWithoutTranscriptAccess() throws {
    let data = Data(#"{"session_id":"parent","agent_id":"child","source":"compact"}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(payload.recordID(agent: .claude, event: "SubagentStart")
            == "v1|6:claude|6:parent|5:child")
    #expect(payload.source == "compact")
}

@Test func equalVendorSessionIDsRemainDistinct() {
    let payload = HookPayload(sessionId: "same")
    #expect(payload.recordID(agent: .claude, event: "Stop")
            != payload.recordID(agent: .codex, event: "Stop"))
}

@Test func claudeBackgroundTaskPresenceIsStructuralOnly() throws {
    let data = Data(#"{"session_id":"parent","background_tasks":[{"id":"bg-1","description":"ignored"}]}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(payload.hasBackgroundTasks)
}

@Test func sessionCronsAreCountedApartFromBackgroundTasks() throws {
    let data = Data(#"{"session_id":"parent","session_crons":[{"id":"cron-1","prompt":"private"},{"id":"cron-2"}]}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(!payload.hasBackgroundTasks)
    #expect(payload.sessionCronCount == 2)
    #expect(payload.hasSessionCrons)

    let empty = try JSONDecoder().decode(
        HookPayload.self, from: Data(#"{"session_id":"parent","session_crons":[]}"#.utf8)
    )
    #expect(empty.sessionCronCount == 0)
    #expect(!empty.hasSessionCrons)
    let absent = try JSONDecoder().decode(HookPayload.self, from: Data(#"{"session_id":"parent"}"#.utf8))
    #expect(absent.sessionCronCount == nil)
    let malformed = try JSONDecoder().decode(
        HookPayload.self, from: Data(#"{"session_id":"parent","session_crons":"oops"}"#.utf8)
    )
    #expect(malformed.sessionCronCount == nil)
}

@Test func localBashAndBackgroundShellTasksAreShellWork() throws {
    for type in ["local_bash", "background_shell", "shell", "monitor"] {
        let data = Data(#"{"session_id":"p","background_tasks":[{"type":"\#(type)","status":"running"}]}"#.utf8)
        let payload = try JSONDecoder().decode(HookPayload.self, from: data)
        #expect(payload.backgroundWork == .shellOnly, "type \(type)")
    }
}

@Test func subagentEdgesRequireANonemptyChildIdentity() {
    for event in ["SubagentStart", "SubagentStop"] {
        #expect(HookPayload(sessionId: "parent")
            .recordID(agent: .claude, event: event) == nil)
        #expect(HookPayload(sessionId: "parent", agentId: "")
            .recordID(agent: .claude, event: event) == nil)
    }
}

@Test func emptyChildIdentityDoesNotChangeParentCanonicalization() {
    #expect(HookPayload(sessionId: "parent", agentId: "")
        .recordID(agent: .claude, event: "SubagentStart") == nil)
    #expect(HookPayload(sessionId: "parent", agentId: "")
        .recordID(agent: .claude, event: "Stop")
        == "v1|6:claude|6:parent|0:")
}

// MARK: - Background task classification (captured from Claude Code 2.1.x Stop payloads)

@Test func shellOnlyBackgroundWorkIsDistinguishedFromAgentWork() throws {
    let shell = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","background_tasks":[
      {"id":"by7dluj9t","type":"shell","status":"running","description":"private","command":"private"}]}
    """#.utf8))
    #expect(shell.backgroundWork == .shellOnly)
    #expect(shell.hasBackgroundTasks)

    let mixed = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","background_tasks":[
      {"id":"a1ae869a95e1a9a18","type":"subagent","status":"running","agent_type":"general-purpose"},
      {"id":"beyuypx27","type":"shell","status":"running"}]}
    """#.utf8))
    #expect(mixed.backgroundWork == .agent)

    let monitor = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","background_tasks":[{"id":"m","type":"Monitor ","status":"running","server":"x"}]}
    """#.utf8))
    #expect(monitor.backgroundWork == .shellOnly)
}

@Test func unknownOrMissingTaskTypesCountAsAgentWork() throws {
    for task in [#"{"id":"t","status":"running"}"#,
                 #"{"id":"t","type":"cloud session","status":"running"}"#,
                 #"{"id":"t","type":"teammate","status":"running"}"#,
                 #"{"id":"t","type":42,"status":"running"}"#,
                 #"{"id":"t","type":"shell"}"#,
                 #"{"id":"t","type":"shell","status":null}"#] {
        let payload = try JSONDecoder().decode(
            HookPayload.self,
            from: Data("{\"session_id\":\"s\",\"background_tasks\":[\(task)]}".utf8)
        )
        let expected: HookPayload.BackgroundWork = task.contains(#""type":"shell""#) ? .shellOnly : .agent
        #expect(payload.backgroundWork == expected, "task: \(task)")
    }
}

@Test func terminalStatusesNeverCountAsWork() throws {
    let statuses = ["idle", "done", "success", "succeeded", "complete", "completed", "finished",
                    "failed", "error", "terminated", "exited", "aborted", "expired", "skipped",
                    "crashed", "killed", "cancelled", "canceled", "timed_out", "Completed", " killed "]
    let tasks = statuses.map { #"{"id":"t","type":"subagent","status":"\#($0)"}"# }
        .joined(separator: ",")
    let payload = try JSONDecoder().decode(
        HookPayload.self,
        from: Data("{\"session_id\":\"s\",\"background_tasks\":[\(tasks)]}".utf8)
    )
    #expect(payload.backgroundWork == .none)
    #expect(!payload.hasBackgroundTasks)
    #expect(payload.hasBackgroundTaskSnapshot)
    #expect(payload.runningBackgroundTaskIDs == [])
}

@Test func subagentStopSnapshotIsJudgedWithoutTheStoppingChild() throws {
    // A backgrounded subagent's own SubagentStop still lists it as running.
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","agent_id":"a1ae869a95e1a9a18","hook_event_name":"SubagentStop",
     "background_tasks":[
      {"id":"a1ae869a95e1a9a18","type":"subagent","status":"running"},
      {"id":"beyuypx27","type":"shell","status":"running"}]}
    """#.utf8))
    #expect(payload.backgroundWork == .agent)
    #expect(payload.backgroundWork(excludingTaskID: payload.agentId) == .shellOnly)

    let alone = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","agent_id":"child","background_tasks":[{"id":"child","type":"subagent","status":"running"}]}
    """#.utf8))
    #expect(alone.backgroundWork(excludingTaskID: "child") == .none)
}

@Test func runningTaskInventoryRequiresEveryEntryToBeIdentified() throws {
    let complete = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","background_tasks":[
      {"id":"child-a","type":"subagent","status":"running"},
      {"id":"child-b","type":"subagent","status":"completed"},
      {"id":"sh","type":"shell","status":"running"}]}
    """#.utf8))
    #expect(complete.runningBackgroundTaskIDs == ["child-a", "sh"])

    let anonymous = try JSONDecoder().decode(HookPayload.self, from: Data(#"""
    {"session_id":"s","background_tasks":[{"id":"child-a","type":"subagent","status":"running"},{"description":"ignored"}]}
    """#.utf8))
    #expect(anonymous.runningBackgroundTaskIDs == nil)
    #expect(anonymous.backgroundWork == .agent)

    let absent = try JSONDecoder().decode(HookPayload.self, from: Data(#"{"session_id":"s"}"#.utf8))
    #expect(absent.runningBackgroundTaskIDs == nil)
    #expect(absent.backgroundWork == .none)
    #expect(!absent.hasBackgroundTaskSnapshot)
}
