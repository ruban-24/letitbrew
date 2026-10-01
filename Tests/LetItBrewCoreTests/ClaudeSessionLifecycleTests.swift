import Dispatch
import Foundation
import Testing
@testable import LetItBrewCore

private func withClaudeLifecycleStorage(_ body: (SessionStorage) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-claude-lifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(SessionStorage(directory: directory))
}

private func claudeEdge(
    _ storage: SessionStorage, _ event: String, _ time: TimeInterval,
    _ fields: String = #""session_id":"parent""#,
    agent: AgentID = .claude
) throws {
    let payload = try JSONDecoder().decode(
        HookPayload.self, from: Data("{\(fields)}".utf8)
    )
    try HookSessionUpdater.apply(
        event: event, payload: payload, agent: agent, agentPID: nil,
        observedAt: Date(timeIntervalSince1970: time), storage: storage
    )
}

private let claudeParentID = "v1|6:claude|6:parent|0:"
private let claudeChildID = "v1|6:claude|6:parent|5:child"

@Test func claudeLastChildCompletionReleasesStoppedParent() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SubagentStart", 11, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "Stop", 20, #""session_id":"parent","background_tasks":[{"id":"child","type":"subagent","status":"running"}]"#)
        try claudeEdge(storage, "SubagentStop", 30, #""session_id":"parent","agent_id":"child","background_tasks":[]"#)

        let parent = try #require(storage.load(id: claudeParentID))
        #expect(parent.state == .idle)
        #expect(parent.lastEvent == "SubagentStop")
        #expect(parent.accumulatedWorkingTime == 20)
        #expect(storage.load(id: claudeChildID) == nil)
        let decision = decide(
            sessions: storage.loadAll(), now: Date(timeIntervalSince1970: 31),
            settings: Settings(),
            power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
        )
        #expect(!decision.holdSystem)
    }
}

@Test func claudeChildCompletionWithFinishedBackgroundTasksReleasesParent() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "Stop", 20, #""session_id":"parent","background_tasks":[{"status":"running"}]"#)
        try claudeEdge(storage, "SubagentStop", 30, #""session_id":"parent","agent_id":"child","background_tasks":[{"status":"completed"},{"status":"cancelled"}]"#)
        #expect(storage.load(id: claudeParentID)?.state == .idle)
    }
}

@Test func claudeChildCompletionDoesNotClearOtherBackgroundWork() throws {
    for task in [#"{"type":"shell","status":"running"}"#, #"{"status":"future-status"}"#, #"{}"#] {
        try withClaudeLifecycleStorage { storage in
            try claudeEdge(storage, "Stop", 20, #""session_id":"parent","background_tasks":[{"status":"running"}]"#)
            try claudeEdge(storage, "SubagentStop", 30, "\"session_id\":\"parent\",\"agent_id\":\"child\",\"background_tasks\":[\(task)]")
            #expect(storage.load(id: claudeParentID)?.state == .working)
        }
    }
}

@Test func claudeMissingBackgroundSnapshotCannotClearStoppedParent() throws {
    for suffix in ["", #", "background_tasks":null"#] {
        try withClaudeLifecycleStorage { storage in
            try claudeEdge(storage, "Stop", 20, #""session_id":"parent","background_tasks":[{"status":"running"}]"#)
            try claudeEdge(storage, "SubagentStop", 30, #""session_id":"parent","agent_id":"child""# + suffix)
            #expect(storage.load(id: claudeParentID)?.state == .working)
        }
    }
}

@Test func claudeChildCompletionCannotStopForegroundTurn() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "Stop", 20, #""session_id":"parent","background_tasks":[{"status":"running"}]"#)
        try claudeEdge(storage, "UserPromptSubmit", 25)
        try claudeEdge(storage, "SubagentStop", 30, #""session_id":"parent","agent_id":"child","background_tasks":[]"#)
        #expect(storage.load(id: claudeParentID)?.state == .working)
        #expect(storage.load(id: claudeParentID)?.lastEvent == "UserPromptSubmit")
    }
}

@Test func claudeOldChildCompletionCannotClearNewerStop() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "Stop", 40, #""session_id":"parent","background_tasks":[{"status":"running"}]"#)
        try claudeEdge(storage, "SubagentStop", 30, #""session_id":"parent","agent_id":"child","background_tasks":[]"#)
        #expect(storage.load(id: claudeParentID)?.state == .working)
        #expect(storage.load(id: claudeParentID)?.eventObservedAt == 40)
    }
}

@Test func claudeSessionEndClearsItsChildrenOnly() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SubagentStart", 11, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "SubagentStart", 12, #""session_id":"parent","agent_id":"second""#)
        try claudeEdge(storage, "SubagentStart", 13, #""session_id":"parent-other","agent_id":"child""#)
        try claudeEdge(storage, "SubagentStart", 14, #""session_id":"parent","agent_id":"child""#, agent: .codex)
        try claudeEdge(storage, "SessionEnd", 30)

        #expect(storage.load(id: claudeParentID) == nil)
        #expect(storage.load(id: claudeChildID) == nil)
        #expect(Set(storage.loadAll().map(\.id)) == [
            "v1|6:claude|12:parent-other|5:child", "v1|5:codex|6:parent|5:child",
        ])
    }
}

@Test func claudeChildSessionEndDoesNotEndParentOrSibling() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SubagentStart", 11, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "SubagentStart", 12, #""session_id":"parent","agent_id":"second""#)
        try claudeEdge(storage, "SessionEnd", 30, #""session_id":"parent","agent_id":"child""#)
        #expect(storage.load(id: claudeParentID)?.state == .working)
        #expect(storage.load(id: claudeChildID) == nil)
        #expect(storage.loadAll().count == 2)
    }
}

@Test func claudeEndedParentRejectsDelayedAndPreviouslyUnseenChildren() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SessionEnd", 30)
        for time in [20.0, 40.0] {
            try claudeEdge(storage, "SubagentStart", time, #""session_id":"parent","agent_id":"child""#)
            try claudeEdge(storage, "PreToolUse", time, #""session_id":"parent","agent_id":"unseen","tool_name":"Bash""#)
        }
        #expect(storage.loadAll().isEmpty)
        try claudeEdge(storage, "SessionStart", 50)
        try claudeEdge(storage, "SubagentStart", 20, #""session_id":"parent","agent_id":"old-unseen""#)
        try claudeEdge(storage, "SubagentStart", 51, #""session_id":"parent","agent_id":"new-child""#)
        #expect(storage.loadAll().count == 2)
    }
}

@Test func claudeStaleSessionEndCannotClearCurrentChildren() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 40)
        try claudeEdge(storage, "SubagentStart", 41, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "SessionEnd", 30)
        #expect(storage.loadAll().count == 2)
        #expect(storage.load(id: claudeParentID)?.state == .working)
    }
}

@Test func claudeConcurrentSessionEndCannotLeaveOrphanedChildren() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        DispatchQueue.concurrentPerform(iterations: 9) { i in
            do {
                if i == 4 {
                    try claudeEdge(storage, "SessionEnd", 100)
                } else {
                    try claudeEdge(storage, "SubagentStart", Double(20 + i), "\"session_id\":\"parent\",\"agent_id\":\"child-\(i)\"")
                }
            } catch { Issue.record(error) }
        }
        #expect(storage.loadAll().isEmpty)
    }
}

@Test func claudeEndedParentRequiresANewSessionOrPromptBeforeWorkingAgain() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "SessionEnd", 30)
        try claudeEdge(storage, "PostToolUse", 40)
        #expect(storage.loadAll().isEmpty)
        try claudeEdge(storage, "UserPromptSubmit", 50)
        #expect(storage.load(id: claudeParentID)?.state == .working)
    }
}

@Test func claudeSessionEndOlderThanChildActivityCannotCloseFamily() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SubagentStart", 40, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "SessionEnd", 30)
        #expect(storage.load(id: claudeParentID)?.state == .working)
        #expect(storage.load(id: claudeChildID)?.state == .working)
        try claudeEdge(storage, "SubagentStop", 50, #""session_id":"parent","agent_id":"child""#)
        #expect(storage.load(id: claudeChildID) == nil)
    }
}

@Test func claudeResumedFamilyRejectsEarlierChildrenWithinTheSameSecond() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "SessionEnd", 30)
        try claudeEdge(storage, "SessionStart", 50.8)
        try claudeEdge(storage, "UserPromptSubmit", 50.9)
        try claudeEdge(storage, "SubagentStart", 50.5, #""session_id":"parent","agent_id":"child""#)
        #expect(storage.load(id: claudeChildID) == nil)
        try claudeEdge(storage, "SubagentStart", 51, #""session_id":"parent","agent_id":"child""#)
        #expect(storage.load(id: claudeChildID)?.state == .working)
    }
}

@Test func claudeInterruptedCleanupCannotKeepEndedFamilyAwake() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SubagentStart", 20, #""session_id":"parent","agent_id":"child""#)
        // Model a process exit after committing the parent terminal, before
        // deleting any children. This is real persisted state, not a mock.
        try storage.mutate(id: claudeParentID, observedAt: 30) { _ in .delete }
        #expect(storage.load(id: claudeChildID) != nil)
        #expect(storage.loadAll().isEmpty)
        let decision = decide(
            sessions: storage.loadAll(), now: Date(timeIntervalSince1970: 31),
            settings: Settings(),
            power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
        )
        #expect(!decision.holdSystem)
        try claudeEdge(storage, "SessionStart", 50.8)
        #expect(storage.loadAll().map(\.id) == [claudeParentID])
        try claudeEdge(storage, "SubagentStart", 51, #""session_id":"parent","agent_id":"new-child""#)
        #expect(storage.loadAll().count == 2)
    }
}

@Test func claudeFirstParentObservationDoesNotInvalidateExistingChild() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "SubagentStart", 10, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "Stop", 20)
        #expect(storage.loadAll().count == 2)
        try claudeEdge(storage, "SubagentStart", 15, #""session_id":"parent","agent_id":"second""#)
        #expect(storage.loadAll().count == 3)
    }
}

@Test func claudeSiblingWorkStillHoldsAfterParentReconciliation() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "SubagentStart", 10, #""session_id":"parent","agent_id":"child""#)
        try claudeEdge(storage, "SubagentStart", 11, #""session_id":"parent","agent_id":"second""#)
        try claudeEdge(storage, "Stop", 20, #""session_id":"parent","background_tasks":[{"status":"running"}]"#)
        try claudeEdge(storage, "SubagentStop", 30, #""session_id":"parent","agent_id":"child","background_tasks":[]"#)
        #expect(storage.load(id: claudeParentID)?.state == .idle)
        let records = storage.loadAll()
        #expect(records.contains { $0.id == "v1|6:claude|6:parent|6:second" && $0.state == .working })
        #expect(decide(
            sessions: records, now: Date(timeIntervalSince1970: 31), settings: Settings(),
            power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
        ).holdSystem)
    }
}

@Test func claudeChildLockTimeoutDoesNotKeepEndedFamilyVisible() throws {
    try withClaudeLifecycleStorage { storage in
        try claudeEdge(storage, "UserPromptSubmit", 10)
        try claudeEdge(storage, "SubagentStart", 20, #""session_id":"parent","agent_id":"child""#)
        // Hold the real child lock while termination commits the parent and
        // attempts its bounded cleanup. No production fault-injection seam.
        try storage.mutate(id: claudeChildID) { _ in
            #expect(throws: SessionStorageMutationError.lockTimedOut) {
                try claudeEdge(storage, "SessionEnd", 30)
            }
            return .keep
        }
        #expect(storage.load(id: claudeChildID) != nil)
        #expect(storage.loadAll().isEmpty)
        try claudeEdge(storage, "SubagentStop", 40, #""session_id":"parent","agent_id":"child","background_tasks":[]"#)
        #expect(storage.loadAll().isEmpty)
    }
}
