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

@Test func decodesCursorConversationAndWorkspaceAliases() throws {
    let data = Data(#"{"conversation_id":"cursor-1","workspace_roots":["/work/app"]}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(payload.sessionId == "cursor-1")
    #expect(payload.cwd == "/work/app")
}

@Test func snakeCaseIdentityWinsOverCompatibilityAliases() throws {
    let data = Data(#"{"session_id":"primary","conversation_id":"fallback","sessionId":"camel"}"#.utf8)
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

@Test func cursorSubagentIdentityUsesItsDocumentedAliases() throws {
    let data = Data(#"{"session_id":"wrong","conversation_id":"also-wrong","parent_conversation_id":"parent","subagent_id":"child"}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(payload.recordID(agent: .cursor, event: "SubagentStart")
            == "v1|6:cursor|6:parent|5:child")
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

@Test func sessionCronsDoNotCountAsBackgroundTasks() throws {
    let data = Data(#"{"session_id":"parent","session_crons":[{"id":"cron-1"}]}"#.utf8)
    let payload = try JSONDecoder().decode(HookPayload.self, from: data)
    #expect(!payload.hasBackgroundTasks)
}

@Test func subagentEdgesRequireANonemptyChildIdentity() {
    for event in ["SubagentStart", "SubagentStop"] {
        #expect(HookPayload(sessionId: "parent")
            .recordID(agent: .claude, event: event) == nil)
        #expect(HookPayload(sessionId: "parent", agentId: "")
            .recordID(agent: .claude, event: event) == nil)
    }
}

@Test func emptyIdentityAliasesFallThroughWithoutChangingParentCanonicalization() {
    #expect(HookPayload(
        sessionId: "parent",
        parentConversationId: "",
        agentId: "",
        subagentId: "child"
    ).recordID(agent: .claude, event: "SubagentStart")
        == "v1|6:claude|6:parent|5:child")
    #expect(HookPayload(
        sessionId: "parent",
        agentId: "child",
        subagentId: ""
    ).recordID(agent: .cursor, event: "SubagentStart")
        == "v1|6:cursor|6:parent|5:child")
    #expect(HookPayload(sessionId: "parent", agentId: "")
        .recordID(agent: .claude, event: "Stop")
        == "v1|6:claude|6:parent|0:")
}
