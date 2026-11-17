import Foundation
import Testing
@testable import LetItBrewAppCore

private let start = Date(timeIntervalSince1970: 50_000)
private let present = AlertPresence(lidClosed: false, screenLocked: false, secondsSinceLastInput: 0)
private let enabled = AlertSettings(desktopAlerts: true)

private func session(
    _ id: String = "s1",
    agent: String = "claude",
    project: String = "letitbrew",
    wait: AlertWaitKind? = .approval,
    stateChangedAt: Date = start,
    pid: Int32? = 4182
) -> AlertSessionObservation {
    AlertSessionObservation(
        id: id,
        agent: agent,
        project: project,
        wait: wait,
        stateChangedAt: stateChangedAt,
        agentPID: pid
    )
}

/// Observes `sessions` at each offset from `start` in turn, returning every
/// alert produced along the way.
private func run(
    _ steps: [(TimeInterval, [AlertSessionObservation])],
    settings: AlertSettings = enabled,
    from initial: AlertSnapshot? = nil
) -> [Alert] {
    var previous = initial
    var alerts: [Alert] = []
    for (offset, sessions) in steps {
        let current = AlertSnapshot(
            observedAt: start.addingTimeInterval(offset),
            sessions: sessions,
            previous: previous
        )
        alerts += AlertPolicy.alerts(
            previous: previous,
            current: current,
            presence: present,
            settings: settings
        )
        previous = current
    }
    return alerts
}

@Test func needsYouFiresAtThirtySecondsAndNotBefore() {
    #expect(run([(0, [session()]), (29.9, [session()])]).isEmpty)
    #expect(run([(0, [session()]), (30, [session()])]).count == 1)
    #expect(run([(0, [session()]), (29, [session()]), (30, [session()])]).count == 1)
}

@Test func needsYouFiresOncePerWaitingEpisode() {
    let waiting = session()
    let alerts = run([
        (0, [waiting]), (31, [waiting]), (32, [waiting]), (600, [waiting]),
    ])
    #expect(alerts.count == 1)

    // Answered, then a new wait: a second episode, a second alert.
    let again = session(stateChangedAt: start.addingTimeInterval(700))
    let twoEpisodes = run([
        (0, [waiting]), (31, [waiting]),
        (650, [session(wait: nil)]),
        (700, [again]), (729, [again]), (730, [again]),
    ])
    #expect(twoEpisodes.count == 2)
    #expect(twoEpisodes[0].id != twoEpisodes[1].id)
}

@Test func reapplyingTheSameSnapshotNeverRepeatsAnAlert() {
    let first = AlertSnapshot(observedAt: start, sessions: [session()], previous: nil)
    let crossed = AlertSnapshot(
        observedAt: start.addingTimeInterval(30), sessions: [session()], previous: first
    )
    #expect(AlertPolicy.alerts(previous: first, current: crossed, presence: present, settings: enabled).count == 1)
    let reapplied = AlertSnapshot(
        observedAt: crossed.observedAt, sessions: [session()], previous: crossed
    )
    #expect(AlertPolicy.alerts(previous: crossed, current: reapplied, presence: present, settings: enabled).isEmpty)
}

@Test func firstSnapshotIsABaselineEvenPastThreshold() {
    // Launching while a session has waited for minutes is not a new ping.
    #expect(run([(300, [session()])]).isEmpty)
    #expect(run([(300, [session()]), (301, [session()])]).isEmpty)
}

@Test func reenteringWaitingWithAnOldStateEdgeRestartsTheClock() {
    // An approved command runs (shown Working), exits before the next hook,
    // and the record is Waiting again with its original state edge.
    // Polls are a second apart, so the clock starts at the last poll that
    // still saw it Working.
    let alerts = run([
        (0, [session()]),
        (5, [session(wait: nil)]),
        (99, [session(wait: nil)]),
        (100, [session()]),
        (128.9, [session()]),
    ])
    #expect(alerts.isEmpty)
    #expect(run([
        (0, [session()]), (5, [session(wait: nil)]), (99, [session(wait: nil)]),
        (100, [session()]), (129, [session()]),
    ]).count == 1)
}

@Test func answeredBeforeThirtySecondsNeverAlerts() {
    #expect(run([
        (0, [session()]), (10, [session(wait: nil)]), (40, [session(wait: nil)]),
    ]).isEmpty)
    #expect(run([(0, [session()]), (10, [])]).isEmpty)
}

@Test func aWaitThatBeganBeforeThePreviousPollCountsFromItsEdge() {
    let earlier = session(stateChangedAt: start.addingTimeInterval(-20))
    #expect(run([(0, [session(wait: nil)]), (1, [earlier])]).isEmpty)
    // The session was not waiting at the previous poll, so the clock starts
    // there, not 20 seconds before it.
    #expect(run([(0, [session(wait: nil)]), (1, [earlier]), (29, [earlier])]).isEmpty)
    #expect(run([(0, [session(wait: nil)]), (1, [earlier]), (30, [earlier])]).count == 1)
}

@Test func exactWordingNamesAgentProjectAndWait() {
    let approval = run([(0, [session()]), (30, [session()])])
    #expect(approval.map(\.title) == ["Claude Code needs you · letitbrew"])
    #expect(approval.map(\.body) == ["Waiting for your approval"])

    let answer = run([
        (0, [session(agent: "codex", project: "api-server", wait: .answer)]),
        (30, [session(agent: "codex", project: "api-server", wait: .answer)]),
    ])
    #expect(answer.map(\.title) == ["Codex needs you · api-server"])
    #expect(answer.map(\.body) == ["Waiting for your answer"])

    let unknown = run([
        (0, [session(agent: "mystery", project: "")]),
        (30, [session(agent: "mystery", project: "")]),
    ])
    #expect(unknown.map(\.title) == ["An agent needs you"])
}

@Test func hiddenProjectNamesDropTheFolder() {
    var settings = enabled
    settings.hideProjectNames = true
    let alerts = run([(0, [session()]), (30, [session()])], settings: settings)
    #expect(alerts.map(\.title) == ["Claude Code needs you"])
    #expect(alerts.allSatisfy { !$0.title.contains("letitbrew") && !$0.body.contains("letitbrew") })
}

@Test func alertCarriesKindDestinationSessionAndProcess() {
    let alert = run([(0, [session()]), (30, [session()])]).first
    #expect(alert?.kind == .needsYou)
    #expect(alert?.destinations == [.desktop])
    #expect(alert?.sessionID == "s1")
    #expect(alert?.agentPID == 4182)
}

@Test func nothingIsSentUntilDesktopAlertsAndNeedsYouAreOn() {
    #expect(AlertSettings().desktopAlerts == false)
    #expect(AlertSettings().needsYou == true)
    #expect(AlertSettings().hideProjectNames == false)
    #expect(run([(0, [session()]), (30, [session()])], settings: AlertSettings()).isEmpty)

    var needsYouOff = enabled
    needsYouOff.needsYou = false
    #expect(run([(0, [session()]), (30, [session()])], settings: needsYouOff).isEmpty)
}

@Test func eachWaitingSessionAlertsSeparately() {
    let a = session("a")
    let b = session("b", agent: "gemini", project: "site", wait: .answer,
                    stateChangedAt: start.addingTimeInterval(10))
    let alerts = run([(0, [a, b]), (30, [a, b]), (40, [a, b])])
    #expect(alerts.map(\.sessionID) == ["a", "b"])
    #expect(alerts.map(\.title) == ["Claude Code needs you · letitbrew", "Gemini CLI needs you · site"])
}

@Test func alertTextIsBuiltOnlyFromAgentFolderAndWaitKind() {
    // The policy's input has no field for prompt text, questions, tool names
    // or commands; every output string comes from this fixed vocabulary.
    let alerts = run([
        (0, [session(), session("x", agent: "codex", wait: .answer)]),
        (30, [session(), session("x", agent: "codex", wait: .answer)]),
    ])
    let allowedBodies: Set = ["Waiting for your approval", "Waiting for your answer"]
    #expect(alerts.count == 2)
    for alert in alerts {
        #expect(allowedBodies.contains(alert.body))
        #expect(alert.title.hasSuffix(" needs you · letitbrew"))
    }
}

@Test func alertsTipShowsUntilDismissedOrAlertsAreOn() {
    #expect(AlertsTipPolicy.isShown(dismissed: false, desktopAlerts: false))
    #expect(!AlertsTipPolicy.isShown(dismissed: true, desktopAlerts: false))
    #expect(!AlertsTipPolicy.isShown(dismissed: false, desktopAlerts: true))
    #expect(AlertsTipPolicy.title == "Get alerts when an agent needs you?")
}
