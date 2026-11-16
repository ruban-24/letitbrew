import Foundation
import Testing
@testable import LetItBrewCore

private func cancellationRecord(state: SessionState = .waiting) -> SessionRecord {
    SessionRecord(
        id: HookRecordID(agent: .copilot, parentID: "68dece50-5040-4dca-923a-c4650905852c")!.encoded,
        tool: "copilot", state: state, detail: SessionWaitDetail.approval,
        cwd: "/work", pid: nil,
        updatedAt: Date(timeIntervalSince1970: 100), lastEvent: "Notification",
        eventObservedAt: 100, promptObservedAt: 90
    )
}

private func cancellationEvent(_ type: String, at seconds: TimeInterval = 110) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let timestamp = formatter.string(from: Date(timeIntervalSince1970: seconds))
    return "{\"type\":\"\(type)\",\"timestamp\":\"\(timestamp)\"}\n"
}

@Test(arguments: [SessionState.waiting, .working])
func explicitCopilotAbortReleasesStaleTurn(state: SessionState) {
    let record = cancellationRecord(state: state)
    let data = Data((cancellationEvent("assistant.turn_end")
        + cancellationEvent("abort") + cancellationEvent("session.usage_checkpoint")).utf8)
    let result = CopilotCancellation.reconcile(record, tail: data)
    #expect(result.state == .idle)
    #expect(result.detail == nil)
    #expect(result.lastEvent == "abort")
    #expect(result.eventObservedAt == 110)
    #expect(result.accumulatedWorkingTime == (state == .working ? 10 : 0))
    #expect(CopilotCancellation.reconcile(record, tail: data) == result)
}

@Test(arguments: ["user.message", "assistant.turn_start", "tool.execution_start", "hook.start", "future.event"])
func activityAfterAbortProtectsNewWork(event: String) {
    let record = cancellationRecord()
    let data = Data((cancellationEvent("abort") + cancellationEvent(event, at: 111)).utf8)
    #expect(CopilotCancellation.reconcile(record, tail: data) == record)
}

@Test func oldCancellationAndNonterminalEventsDoNotRelease() {
    let record = cancellationRecord()
    for log in [cancellationEvent("abort", at: 99), cancellationEvent("abort", at: 100),
                cancellationEvent("assistant.turn_end"), cancellationEvent("permission.completed"),
                cancellationEvent("tool.execution_complete"), "",
                cancellationEvent("abort") + "{", "garbage\n" + cancellationEvent("abort")] {
        #expect(CopilotCancellation.reconcile(record, tail: Data(log.utf8)) == record)
    }
    var newerPrompt = record
    newerPrompt.promptObservedAt = 120
    #expect(CopilotCancellation.reconcile(
        newerPrompt, tail: Data(cancellationEvent("abort").utf8)
    ) == newerPrompt)
    var claude = record
    claude.tool = "claude"
    #expect(CopilotCancellation.reconcile(
        claude, tail: Data(cancellationEvent("abort").utf8)
    ) == claude)
}

@Test func cancellationReleasesARunningApprovalsSleepHold() {
    var waiting = cancellationRecord()
    waiting.pid = 4_242
    let now = Date(timeIntervalSince1970: 111)
    let power = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    let command = [AgentChildProcess(pid: 4_243, parentPID: 4_242, processGroup: 4_243,
                                     startedAt: Date(timeIntervalSince1970: 105))]
    #expect(decide(sessions: [waiting], now: now, settings: Settings(), power: power,
                   runningApprovals: .observing([waiting], children: command, now: now))
        .holdLidClosed)
    let cancelled = CopilotCancellation.reconcile(
        waiting, tail: Data(cancellationEvent("abort").utf8)
    )
    let decision = decide(sessions: [cancelled], now: now, settings: Settings(), power: power,
                          runningApprovals: .observing([cancelled], children: command, now: now))
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    let resumed = CopilotCancellation.reconcile(
        waiting, tail: Data((cancellationEvent("abort") + cancellationEvent("user.message", at: 111)).utf8)
    )
    #expect(resumed == waiting)
}

@Test func cancellationReadsBoundedTailFromRecordedCopilotHome() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    var record = cancellationRecord()
    record.copilotHome = home.path
    let id = try #require(HookRecordID(encoded: record.id))
    let directory = home.appendingPathComponent("session-state").appendingPathComponent(id.parentID)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("events.jsonl")
    #expect(CopilotCancellation.reconcile([record]) == [record])
    let log = String(repeating: cancellationEvent("assistant.message"), count: 6000)
        + cancellationEvent("abort") + cancellationEvent("session.usage_checkpoint")
    try Data(log.utf8).write(to: url)
    #expect(CopilotCancellation.reconcile([record]).first?.state == .idle)
    let encoder = JSONEncoder()
    let decoded = try JSONDecoder().decode(SessionRecord.self, from: encoder.encode(record))
    #expect(decoded.copilotHome == home.path)
    try FileManager.default.removeItem(at: url)
    let target = home.appendingPathComponent("target")
    try Data(cancellationEvent("abort").utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
    #expect(CopilotCancellation.reconcile([record]) == [record])
}
