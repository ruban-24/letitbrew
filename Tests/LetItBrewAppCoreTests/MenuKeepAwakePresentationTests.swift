import Foundation
import Testing
import LetItBrewAppCore
import LetItBrewCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// Stands in for the locale's short time, so the copy is deterministic.
private func clock(_ date: Date) -> String {
    date == now.addingTimeInterval(6_120) ? "3:56 PM" : "other"
}

private func session(deadlineIn seconds: TimeInterval?) -> ManualSessionRecord {
    ManualSessionRecord(startedAt: now, deadline: seconds.map(now.addingTimeInterval),
                        bootSessionID: "boot")
}

private func agentRows(_ states: [MenuSessionState]) -> [MenuSessionPresentation] {
    MenuSessionPresentationPolicy.rows(
        from: states.enumerated().map {
            SessionMenuInput(id: "s\($0.offset)", tool: "claude", project: "app",
                             repositoryPath: "/work/app", state: $0.element,
                             activeWorkingTime: 60, updatedAt: now)
        },
        now: now
    )
}

@Test func timedSessionRowCountsDownWithExtendAndEnd() {
    let row = MenuKeepAwakePresentationPolicy.running(
        session(deadlineIn: 6_120), now: now, isHeldBack: false, formatTime: clock
    )
    #expect(row.title == "Awake · 1:42 left")
    #expect(row.status == "Awake")
    #expect(row.timeLeft == "1:42")
    #expect(row.detail == "Until 3:56 PM")
    #expect(row.canExtend)
}

@Test func timeLeftRoundsUpToTheMinute() {
    func left(_ seconds: TimeInterval) -> String? {
        MenuKeepAwakePresentationPolicy.running(
            session(deadlineIn: seconds), now: now, isHeldBack: false, formatTime: clock
        ).timeLeft
    }
    #expect(left(30 * 60) == "0:30")
    #expect(left(30 * 60 - 0.5) == "0:30")
    #expect(left(4 * 3_600) == "4:00")
    #expect(left(6_061) == "1:42")
    #expect(left(59) == "0:01")
    #expect(left(10 * 3_600 + 5 * 60) == "10:05")
}

@Test func indefiniteSessionRowHasNoTimeLimitAndOnlyEnd() {
    let row = MenuKeepAwakePresentationPolicy.running(
        session(deadlineIn: nil), now: now, isHeldBack: false, formatTime: clock
    )
    #expect(row.title == "Awake · No time limit")
    #expect(row.timeLeft == nil)
    #expect(row.detail == "Until you end it")
    #expect(!row.canExtend)
}

@Test func heldBackSessionRowSaysSo() {
    let timed = MenuKeepAwakePresentationPolicy.running(
        session(deadlineIn: 6_120), now: now, isHeldBack: true, formatTime: clock
    )
    #expect(timed.title == "Held back · 1:42 left")
    #expect(timed.detail == "Until 3:56 PM")
    #expect(timed.canExtend)

    let indefinite = MenuKeepAwakePresentationPolicy.running(
        session(deadlineIn: nil), now: now, isHeldBack: true, formatTime: clock
    )
    #expect(indefinite.title == "Held back · No time limit")
}

@Test func headerDetailNamesTheSessionWhileItKeepsTheMacAwake() {
    func detail(_ session: ManualSessionRecord?, awake: Bool = true, heldBack: Bool = false,
                rows: [MenuSessionPresentation] = [], holds: Int = 0) -> String? {
        MenuKeepAwakePresentationPolicy.headerDetail(
            session: session, isKeepingAwake: awake, isHeldBack: heldBack,
            rows: rows, holdCount: holds, now: now, formatTime: clock
        )
    }
    #expect(detail(session(deadlineIn: 6_120)) == "You asked to keep it awake until 3:56 PM")
    #expect(detail(session(deadlineIn: nil)) == "You asked to keep it awake")
    #expect(detail(session(deadlineIn: 6_120), rows: agentRows([.working]))
            == "You asked to keep it awake until 3:56 PM · 1 agent is working")
    #expect(detail(session(deadlineIn: nil), holds: 1)
            == "You asked to keep it awake · 1 command is holding")
    #expect(detail(session(deadlineIn: nil), rows: agentRows([.waitingForApproval]))
            == "You asked to keep it awake · 1 waiting")
    #expect(detail(session(deadlineIn: nil), awake: false, heldBack: true)
            == "Your keep-awake session is held back")

    // Without a running session the existing header copy applies.
    #expect(detail(nil) == nil)
    #expect(detail(session(deadlineIn: nil), awake: false) == nil)
    #expect(detail(session(deadlineIn: -1)) == nil)
}

@Test func pausedCaptionExplainsThatStartingResumes() {
    #expect(MenuKeepAwakePresentationPolicy.pausedCaption
            == "Starting one turns Let It Brew back on.")
}
