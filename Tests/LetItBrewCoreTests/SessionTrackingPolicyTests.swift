import Foundation
import Testing
@testable import LetItBrewCore

private let trackingNow = Date(timeIntervalSince1970: 1_800_000_000)

private func trackedSession(
    id: String = "session",
    tool: String = "codex",
    state: SessionState = .working,
    detail: String? = nil,
    event: String = "UserPromptSubmit",
    updatedAt: Date = trackingNow,
    eventObservedAt: TimeInterval? = nil
) -> SessionRecord {
    SessionRecord(
        id: id,
        tool: tool,
        state: state,
        detail: detail,
        cwd: "/tmp/project",
        pid: 42,
        updatedAt: updatedAt,
        lastEvent: event,
        startedAt: trackingNow.addingTimeInterval(-300),
        stateChangedAt: updatedAt,
        stateTransitionID: "edge-\(updatedAt.timeIntervalSince1970)",
        eventObservedAt: eventObservedAt
    )
}

@Test func SubsecondWorkEdgeReenablesTrackingWithinTheSameEncodedSecond() {
    let original = trackedSession(eventObservedAt: trackingNow.timeIntervalSince1970 + 0.1)
    let newer = trackedSession(eventObservedAt: trackingNow.timeIntervalSince1970 + 0.8)

    let result = SessionTrackingPolicy.applying(
        [SessionTrackingSuppression(session: original)],
        to: [newer]
    )

    #expect(result.sessions == [newer])
    #expect(result.suppressions.isEmpty)
}

@Test func stopTrackingHidesTheExactSessionRevisionAndReleasesItsHold() {
    let session = trackedSession()
    let suppression = SessionTrackingSuppression(session: session)

    let result = SessionTrackingPolicy.applying([suppression], to: [session])
    let decision = decide(
        sessions: result.sessions,
        now: trackingNow,
        settings: Settings(),
        power: PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)
    )

    #expect(result.sessions.isEmpty)
    #expect(result.suppressions == [suppression])
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
}

@Test func newerWorkEventAutomaticallyReenablesTheSameSession() {
    let original = trackedSession()
    let newer = trackedSession(
        event: "PreToolUse",
        updatedAt: trackingNow.addingTimeInterval(5)
    )

    let result = SessionTrackingPolicy.applying(
        [SessionTrackingSuppression(session: original)],
        to: [newer]
    )

    #expect(result.sessions == [newer])
    #expect(result.suppressions.isEmpty)
}

@Test func onlyWorkingRevisionsResurrectAStoppedSession() {
    let original = trackedSession()
    let idle = trackedSession(
        state: .idle,
        event: "Stop",
        updatedAt: trackingNow.addingTimeInterval(1)
    )
    let afterIdle = SessionTrackingPolicy.applying(
        [SessionTrackingSuppression(session: original)],
        to: [idle]
    )
    #expect(afterIdle.sessions.isEmpty)
    #expect(afterIdle.suppressions == [SessionTrackingSuppression(session: idle)])

    let working = trackedSession(
        event: "UserPromptSubmit",
        updatedAt: trackingNow.addingTimeInterval(2)
    )
    let afterWork = SessionTrackingPolicy.applying(
        afterIdle.suppressions,
        to: [working]
    )
    #expect(afterWork.sessions == [working])
    #expect(afterWork.suppressions.isEmpty)
}

@Test func SuppressionAffectsOnlyTheSelectedSessionAndSurvivesItsAbsence() {
    // Agent session ids are external input. Even an identical id from another
    // agent must remain a separate trackable session.
    let selected = trackedSession(id: "shared-id")
    let other = trackedSession(id: "shared-id", tool: "claude")
    let suppression = SessionTrackingSuppression(session: selected)

    let mixed = SessionTrackingPolicy.applying([suppression], to: [selected, other])
    #expect(mixed.sessions == [other])

    let absent = SessionTrackingPolicy.applying(mixed.suppressions, to: [other])
    #expect(absent.sessions == [other])
    #expect(absent.suppressions == [suppression])
}

@Test func SuppressionsRoundTripForRelaunchPersistence() throws {
    let suppression = SessionTrackingSuppression(session: trackedSession())

    let data = try JSONEncoder().encode([suppression])
    let decoded = try JSONDecoder().decode(
        [SessionTrackingSuppression].self,
        from: data
    )

    #expect(decoded == [suppression])
}

@Test func aTurnEndingInMonitoringDoesNotBringBackAStoppedSession() {
    let original = trackedSession(tool: "claude")
    let monitoring = trackedSession(
        tool: "claude",
        detail: SessionWorkDetail.backgroundShell,
        event: "Stop",
        updatedAt: trackingNow.addingTimeInterval(5)
    )

    let hidden = SessionTrackingPolicy.applying(
        [SessionTrackingSuppression(session: original)],
        to: [monitoring]
    )
    #expect(hidden.sessions.isEmpty)
    #expect(hidden.suppressions.count == 1)

    // A new prompt is genuine work again.
    let prompt = trackedSession(
        tool: "claude",
        event: "UserPromptSubmit",
        updatedAt: trackingNow.addingTimeInterval(10)
    )
    let shown = SessionTrackingPolicy.applying(hidden.suppressions, to: [prompt])
    #expect(shown.sessions == [prompt])
    #expect(shown.suppressions.isEmpty)
}
