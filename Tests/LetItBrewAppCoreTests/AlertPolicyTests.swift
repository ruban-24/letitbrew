import Foundation
import Testing
import LetItBrewCore
@testable import LetItBrewAppCore

private let start = Date(timeIntervalSince1970: 50_000)
private let present = AlertPresence(lidClosed: false, screenLocked: false, secondsSinceLastInput: 0)
private let enabled = AlertSettings(desktopAlerts: true)

private func session(
    _ id: String = "s1",
    agent: String = "claude",
    project: String = "letitbrew",
    wait: AlertWaitKind? = .approval,
    working: Bool = false,
    idle: Bool = false,
    stateChangedAt: Date = start,
    pid: Int32? = 4182
) -> AlertSessionObservation {
    AlertSessionObservation(
        id: id,
        agent: agent,
        project: project,
        wait: wait,
        working: working,
        idle: idle,
        stateChangedAt: stateChangedAt,
        agentPID: pid
    )
}

private func working(
    _ id: String = "s1",
    agent: String = "claude",
    project: String = "letitbrew",
    since: TimeInterval = 0
) -> AlertSessionObservation {
    session(id, agent: agent, project: project, wait: nil, working: true,
            stateChangedAt: start.addingTimeInterval(since))
}

private func idle(
    _ id: String = "s1",
    agent: String = "claude",
    project: String = "letitbrew",
    since: TimeInterval
) -> AlertSessionObservation {
    session(id, agent: agent, project: project, wait: nil, idle: true,
            stateChangedAt: start.addingTimeInterval(since))
}

/// Everything alerts see at one poll, `at` seconds after `start`.
private struct Poll {
    var at: TimeInterval
    var sessions: [AlertSessionObservation] = []
    var holds: [AlertHold] = []
    var ended: [AlertHoldResult] = []
    var machine = AlertMachineState()
    /// Overrides the run's presence for this poll.
    var presence: AlertPresence?
}

/// Held awake with work wanting it, lid closed, network up.
private let heldClosed = AlertMachineState(
    held: true, holdWanted: true, releasedBy: nil, lidClosed: true, networkReachable: true
)

private func released(_ rule: PowerRule, wanted: Bool = true) -> AlertMachineState {
    AlertMachineState(held: false, holdWanted: wanted, releasedBy: rule, lidClosed: true,
                      networkReachable: true)
}

private func offline(held: Bool = true, lidClosed: Bool = true) -> AlertMachineState {
    AlertMachineState(held: held, holdWanted: held, releasedBy: nil, lidClosed: lidClosed,
                      networkReachable: false)
}

private func hold(_ label: String = "npm run build", id: String = "4182") -> AlertHold {
    AlertHold(id: id, label: label, startedAt: start)
}

private func ended(
    _ label: String = "npm run build",
    after minutes: TimeInterval,
    status: Int32
) -> AlertHoldResult {
    AlertHoldResult(hold: hold(label), endedAt: start.addingTimeInterval(minutes * 60), exitStatus: status)
}

private func run(
    _ polls: [Poll],
    settings: AlertSettings = enabled,
    presence: AlertPresence = present
) -> [Alert] {
    var previous: AlertSnapshot?
    var alerts: [Alert] = []
    for poll in polls {
        var current = AlertSnapshot(
            observedAt: start.addingTimeInterval(poll.at),
            sessions: poll.sessions,
            holds: poll.holds,
            endedHolds: poll.ended,
            machine: poll.machine,
            previous: previous
        )
        alerts += AlertPolicy.alerts(
            previous: previous,
            current: &current,
            presence: poll.presence ?? presence,
            settings: settings
        )
        previous = current
    }
    return alerts
}

/// Observes `sessions` at each offset from `start` in turn, returning every
/// alert produced along the way.
private func run(
    _ steps: [(TimeInterval, [AlertSessionObservation])],
    settings: AlertSettings = enabled,
    presence: AlertPresence = present
) -> [Alert] {
    run(steps.map { ($0.0, $0.1, presence) }, settings: settings)
}

/// Like `run`, with the presence read at each poll.
private func run(
    _ steps: [(TimeInterval, [AlertSessionObservation], AlertPresence)],
    settings: AlertSettings = phoneSetUp
) -> [Alert] {
    var previous: AlertSnapshot?
    var alerts: [Alert] = []
    for (offset, sessions, presence) in steps {
        var current = AlertSnapshot(
            observedAt: start.addingTimeInterval(offset),
            sessions: sessions,
            previous: previous
        )
        alerts += AlertPolicy.alerts(
            previous: previous,
            current: &current,
            presence: presence,
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
    var crossed = AlertSnapshot(
        observedAt: start.addingTimeInterval(30), sessions: [session()], previous: first
    )
    #expect(AlertPolicy.alerts(previous: first, current: &crossed, presence: present, settings: enabled).count == 1)
    var reapplied = AlertSnapshot(
        observedAt: crossed.observedAt, sessions: [session()], previous: crossed
    )
    #expect(AlertPolicy.alerts(previous: crossed, current: &reapplied, presence: present, settings: enabled).isEmpty)
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
    #expect(approval.map(\.title) == ["Claude Code needs you"])
    #expect(approval.map(\.body) == ["letitbrew · Waiting for your approval"])

    let question = run([(0, [session(wait: .answer)]), (30, [session(wait: .answer)])])
    #expect(question.map(\.title) == ["Claude Code needs you"])
    #expect(question.map(\.body) == ["letitbrew · Waiting for your answer"])

    let answer = run([
        (0, [session(agent: "codex", project: "api-server", wait: .answer)]),
        (30, [session(agent: "codex", project: "api-server", wait: .answer)]),
    ])
    #expect(answer.map(\.title) == ["Codex needs you"])
    #expect(answer.map(\.body) == ["api-server · Waiting for your answer"])

    let unknown = run([
        (0, [session(agent: "mystery", project: "")]),
        (30, [session(agent: "mystery", project: "")]),
    ])
    #expect(unknown.map(\.title) == ["An agent needs you"])
    #expect(unknown.map(\.body) == ["Waiting for your approval"])
}

@Test func hiddenProjectNamesDropTheFolder() {
    var settings = enabled
    settings.hideProjectNames = true
    let alerts = run([(0, [session()]), (30, [session()])], settings: settings)
    #expect(alerts.map(\.title) == ["Claude Code needs you"])
    #expect(alerts.map(\.body) == ["Waiting for your approval"])
    let question = run([(0, [session(wait: .answer)]), (30, [session(wait: .answer)])], settings: settings)
    #expect(question.map(\.body) == ["Waiting for your answer"])
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
    #expect(alerts.map(\.title) == ["Claude Code needs you", "Gemini CLI needs you"])
    #expect(alerts.map(\.body) == ["letitbrew · Waiting for your approval", "site · Waiting for your answer"])
}

@Test func alertTextIsBuiltOnlyFromAgentFolderAndWaitKind() {
    // The policy's input has no field for prompt text, questions, tool names
    // or commands; every output string comes from this fixed vocabulary.
    let alerts = run([
        (0, [session(), session("x", agent: "codex", wait: .answer)]),
        (30, [session(), session("x", agent: "codex", wait: .answer)]),
    ])
    let allowedBodies: Set = ["letitbrew · Waiting for your approval", "letitbrew · Waiting for your answer"]
    #expect(alerts.count == 2)
    for alert in alerts {
        #expect(allowedBodies.contains(alert.body))
        #expect(alert.title.hasSuffix(" needs you"))
    }
}

@Test func alertsTipShowsUntilDismissedOrAlertsAreOn() {
    #expect(AlertsTipPolicy.isShown(dismissed: false, desktopAlerts: false))
    #expect(!AlertsTipPolicy.isShown(dismissed: true, desktopAlerts: false))
    #expect(!AlertsTipPolicy.isShown(dismissed: false, desktopAlerts: true))
    #expect(AlertsTipPolicy.title == "Get alerts when an agent needs you?")
}

// MARK: Finished

@Test func agentFinishedAlertsWhenWorkOfThreeMinutesGoesIdle() {
    #expect(run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 179, sessions: [working()]),
        Poll(at: 180, sessions: [idle(since: 179.9)]),
    ]).isEmpty)
    let alerts = run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 179, sessions: [working()]),
        Poll(at: 181, sessions: [idle(since: 180)]),
        Poll(at: 182, sessions: [idle(since: 180)]),
    ])
    #expect(alerts.map(\.kind) == [.finished])
    #expect(alerts.map(\.title) == ["Claude Code finished"])
    #expect(alerts.map(\.body) == ["letitbrew · Worked for 3 min"])
}

@Test func agentFinishedAlertsWhenTheSessionEndsAfterThreeMinutes() {
    // Work ends at the last poll that saw it Working.
    #expect(run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 179.9, sessions: [working()]),
        Poll(at: 200, sessions: []),
    ]).isEmpty)
    let alerts = run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 180, sessions: [working()]),
        Poll(at: 181, sessions: []),
        Poll(at: 182, sessions: []),
    ])
    #expect(alerts.map(\.title) == ["Claude Code finished"])
}

@Test func goingWaitingIsNotFinishingAndRestartsTheWorkClock() {
    #expect(run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 200, sessions: [working()]),
        Poll(at: 201, sessions: [session(stateChangedAt: start.addingTimeInterval(201))]),
        Poll(at: 210, sessions: [working(since: 210)]),
        Poll(at: 389, sessions: [working(since: 210)]),
        Poll(at: 390, sessions: [idle(since: 389.9)]),
    ]).isEmpty)
    #expect(run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 201, sessions: [session(stateChangedAt: start.addingTimeInterval(201))]),
        Poll(at: 210, sessions: [working(since: 210)]),
        Poll(at: 391, sessions: [idle(since: 390)]),
    ]).count == 1)
}

@Test func workUnderWayAtLaunchFinishesWithItsFullLength() {
    // The first snapshot is a baseline for crossings, but work that began
    // before launch still ends after it.
    let alerts = run([
        Poll(at: 840, sessions: [working(agent: "codex", project: "api-server")]),
        Poll(at: 841, sessions: [idle(agent: "codex", project: "api-server", since: 841)]),
    ])
    #expect(alerts.map(\.title) == ["Codex finished"])
    #expect(alerts.map(\.body) == ["api-server · Worked for 14 min"])
}

@Test func finishedWordingWithHiddenOrMissingProjectAndUnknownAgent() {
    var hidden = enabled
    hidden.hideProjectNames = true
    let polls = [
        Poll(at: 0, sessions: [working(agent: "codex", project: "api-server")]),
        Poll(at: 841, sessions: [idle(agent: "codex", project: "api-server", since: 840)]),
    ]
    #expect(run(polls, settings: hidden).map(\.body) == ["Worked for 14 min"])
    #expect(run(polls, settings: hidden).allSatisfy { !$0.title.contains("api-server") })

    let unknown = run([
        Poll(at: 0, sessions: [working(agent: "mystery", project: "")]),
        Poll(at: 200, sessions: [idle(agent: "mystery", project: "", since: 200)]),
    ])
    #expect(unknown.map(\.title) == ["An agent finished"])
    #expect(unknown.map(\.body) == ["Worked for 3 min"])
}

@Test func finishedNeedsItsToggleAndAChannel() {
    let polls = [
        Poll(at: 0, sessions: [working()]),
        Poll(at: 200, sessions: [idle(since: 200)]),
    ]
    var off = enabled
    off.finished = false
    #expect(run(polls, settings: off).isEmpty)
    #expect(run(polls, settings: AlertSettings()).isEmpty)
    #expect(AlertSettings().finished == true)
    #expect(run(polls).first?.agentPID == 4182)
}

@Test func heldCommandReportsSuccessOrFailureFromItsExitStatus() {
    let succeeded = run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 1321, ended: [ended(after: 22, status: 0)]),
    ])
    #expect(succeeded.map(\.kind) == [.finished])
    #expect(succeeded.map(\.title) == ["npm finished"])
    #expect(succeeded.map(\.body) == ["Succeeded after 22 min"])
    #expect(succeeded.first?.agentPID == nil)

    let failed = run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 361, ended: [ended(after: 6, status: 1)]),
    ])
    #expect(failed.map(\.title) == ["npm failed"])
    #expect(failed.map(\.body) == ["Failed after 6 min"])

    // Ended by a signal (128 + signal) is a failure too.
    #expect(run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 361, ended: [ended(after: 6, status: 130)]),
    ]).map(\.title) == ["npm failed"])
}

@Test func heldCommandAlertsNameOnlyTheProgram() {
    // Arguments can hold secrets, and a phone alert can go to a public server.
    func title(_ label: String) -> [String] {
        run([
            Poll(at: 0, holds: [hold(label)]),
            Poll(at: 361, ended: [ended(label, after: 6, status: 0)]),
        ]).map(\.title)
    }
    #expect(title("npm run build") == ["npm finished"])
    #expect(title("/usr/local/bin/psql postgres://u:pw@host") == ["psql finished"])
    #expect(title("sh -c sleep 200") == ["sh finished"])
    #expect(title("make") == ["make finished"])
    // Labels without arguments stay whole.
    #expect(title("Process 4182") == ["Process 4182 finished"])
    #expect(title(HoldRecord.terminalLabel) == ["Terminal finished"])
    #expect(title("") == ["A held command finished"])
    // A program path cut short by the label's length limit has no sure name.
    #expect(title(HoldRecord.label(for: ["/Users/me/" + String(repeating: "deep/", count: 12) + "tool", "-v"]))
        == ["A held command finished"])
}

@Test func hiddenProjectNamesHideTheHeldProgramToo() {
    var hidden = enabled
    hidden.hideProjectNames = true
    let label = "/usr/local/bin/psql postgres://u:pw@host"
    #expect(run([
        Poll(at: 0, holds: [hold(label)]),
        Poll(at: 361, ended: [ended(label, after: 6, status: 0)]),
    ], settings: hidden).map(\.title) == ["A held command finished"])
}

@Test func heldCommandOfUnderThreeMinutesNeverAlerts() {
    #expect(run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 180, ended: [ended(after: 179.9 / 60, status: 0)]),
    ]).isEmpty)
    #expect(run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 181, ended: [ended(after: 3, status: 0)]),
    ]).count == 1)
}

@Test func heldCommandAlertsOnceWhileItsResultLingers() {
    // The result can land while the exited process still shows as held.
    let result = ended(after: 22, status: 0)
    let alerts = run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 1320, holds: [hold()], ended: [result]),
        Poll(at: 1321, ended: [result]),
        Poll(at: 1322),
    ])
    #expect(alerts.count == 1)
}

@Test func aReportedHoldStaysReportedWhileItsLiveRecordOutlivesTheResult() {
    // Overlapping polls: one applies the result and removes it, while a
    // later read still sees the live record but no longer the result.
    let alerts = run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 361, holds: [hold()], ended: [ended(after: 6, status: 1)]),
        Poll(at: 362, holds: [hold()]),
        Poll(at: 363),
    ])
    #expect(alerts.map(\.title) == ["npm failed"])
    #expect(alerts.map(\.body) == ["Failed after 6 min"])

    #expect(run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 361, holds: [hold()], ended: [ended(after: 6, status: 1)]),
        Poll(at: 362, holds: [hold()]),
        Poll(at: 363, holds: [hold()]),
        Poll(at: 364, holds: [hold()]),
        Poll(at: 365),
    ]).map(\.title) == ["npm failed"])
}

@Test func holdWithoutAnExitStatusSaysFinished() {
    // `--pid` and bare holds, or a hold whose CLI was killed: the hold
    // vanishes, timed to the last poll that saw it.
    let alerts = run([
        Poll(at: 0, holds: [hold("Process 4182")]),
        Poll(at: 1320, holds: [hold("Process 4182")]),
        Poll(at: 1321),
    ])
    #expect(alerts.map(\.title) == ["Process 4182 finished"])
    #expect(alerts.map(\.body) == ["Finished after 22 min"])
    #expect(run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 179.9, holds: [hold()]),
        Poll(at: 181),
    ]).isEmpty)
}

@Test func hiddenProjectNamesHideTheHeldCommand() {
    var hidden = enabled
    hidden.hideProjectNames = true
    let alerts = run([
        Poll(at: 0, holds: [hold(), hold("make", id: "9")]),
        Poll(at: 400, holds: [hold("make", id: "9")], ended: [ended(after: 6, status: 0)]),
        Poll(at: 401, ended: [AlertHoldResult(hold: hold("make", id: "9"),
                                              endedAt: start.addingTimeInterval(400), exitStatus: 2)]),
        Poll(at: 900, holds: [AlertHold(id: "7", label: "Process 7", startedAt: start.addingTimeInterval(401))]),
        Poll(at: 901),
    ], settings: hidden)
    #expect(alerts.map(\.title) == [
        "A held command finished", "A held command failed", "A held command finished",
    ])
    #expect(alerts.allSatisfy { !$0.title.contains("npm") && !$0.body.contains("npm") })
}

@Test func aHoldResultAtLaunchIsABaseline() {
    #expect(run([
        Poll(at: 1321, ended: [ended(after: 22, status: 0)]),
        Poll(at: 1322),
    ]).isEmpty)
}

// MARK: Stopped for battery or heat

@Test func stoppedForBatteryOrHeatNamesTheRule() {
    func stopped(_ rule: PowerRule) -> [Alert] {
        run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: released(rule))])
    }
    let battery = stopped(.batteryFloor(20))
    #expect(battery.map(\.kind) == [.stoppedForPower])
    #expect(battery.map(\.title) == ["Your Mac stopped keeping awake"])
    #expect(battery.map(\.body) == ["Battery reached 20%."])
    #expect(stopped(.batteryFloor(35)).map(\.body) == ["Battery reached 35%."])
    #expect(stopped(.connectedPowerOnly).map(\.body) == ["It switched to battery power."])
    #expect(stopped(.lowPowerMode).map(\.body) == ["Low Power Mode turned on."])
    #expect(stopped(.thermal).map(\.body) == ["It got too warm."])
    #expect(stopped(.thermal).first?.agentPID == nil)
    // An unreadable battery is not one of the four rules.
    #expect(stopped(.unknownBattery).isEmpty)
}

@Test func stoppedAlertsOncePerReleaseEpisode() {
    let alerts = run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 1, machine: released(.thermal)),
        Poll(at: 2, machine: released(.thermal)),
        Poll(at: 3, machine: released(.batteryFloor(20))),
        Poll(at: 60, machine: released(.thermal)),
    ])
    #expect(alerts.count == 1)

    // Held again, then released again: a second episode.
    let twice = run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 1, machine: released(.thermal)),
        Poll(at: 100, machine: heldClosed),
        Poll(at: 200, machine: released(.thermal)),
    ])
    #expect(twice.count == 2)
    #expect(twice[0].id != twice[1].id)
}

@Test func stoppedNeedsAHoldThatSomethingStillWanted() {
    // Work ended as the rule kicked in: nothing was stopped.
    #expect(run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 1, machine: released(.thermal, wanted: false)),
    ]).isEmpty)
    // Never held: work that starts on a low battery was not stopped.
    #expect(run([
        Poll(at: 0, machine: released(.batteryFloor(20), wanted: false)),
        Poll(at: 1, machine: released(.batteryFloor(20))),
    ]).isEmpty)
    // Paused, or released for no power rule.
    #expect(run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 1, machine: AlertMachineState(held: false, holdWanted: false, releasedBy: nil,
                                               lidClosed: true, networkReachable: true)),
    ]).isEmpty)
}

@Test func stoppedNeedsItsToggleAndAChannel() {
    let polls = [Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: released(.thermal))]
    var off = enabled
    off.stoppedForPower = false
    #expect(run(polls, settings: off).isEmpty)
    #expect(run(polls, settings: AlertSettings()).isEmpty)
    #expect(AlertSettings().stoppedForPower == true)
}

// MARK: Wi-Fi dropped

@Test func wifiDroppedWaitsSixtySecondsOfContinuousOutage() {
    var wifi = enabled
    wifi.wifiDropped = true
    #expect(AlertPolicy.wifiDroppedDelay == 60)
    // First seen down at 10 s; 59.9 s later nothing, at 60 s exactly one.
    #expect(run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 10, machine: offline()),
        Poll(at: 69.9, machine: offline()),
    ], settings: wifi).isEmpty)
    #expect(run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 10, machine: offline()),
        Poll(at: 69.9, machine: offline()),
        Poll(at: 70, machine: offline()),
    ], settings: wifi).map(\.kind) == [.wifiDropped])
    // A drop that recovers within 60 s sends nothing.
    #expect(run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 10, machine: offline()),
        Poll(at: 69, machine: offline()),
        Poll(at: 70, machine: heldClosed),
        Poll(at: 300, machine: heldClosed),
    ], settings: wifi).isEmpty)
}

@Test func wifiDroppedAlertsWhenTheNetworkGoesWhileClosedAndHeld() {
    var wifi = enabled
    wifi.wifiDropped = true
    let alerts = run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 1, machine: offline()),
        Poll(at: 2, machine: offline()),
        Poll(at: 61, machine: offline()),
        Poll(at: 300, machine: offline()),
    ], settings: wifi)
    #expect(alerts.map(\.kind) == [.wifiDropped])
    #expect(alerts.map(\.title) == ["Wi-Fi dropped while your Mac was closed"])
    #expect(alerts.map(\.body) == ["Agents may be stuck until it reconnects."])

    // Back, then gone again for 60 s: a second episode.
    #expect(run([
        Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline()),
        Poll(at: 61, machine: offline()), Poll(at: 62, machine: heldClosed),
        Poll(at: 63, machine: offline()), Poll(at: 123, machine: offline()),
    ], settings: wifi).count == 2)
}

@Test func wifiDroppedNeedsTheLidClosedAndSomethingHeld() {
    var wifi = enabled
    wifi.wifiDropped = true
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline(lidClosed: false)),
                 Poll(at: 300, machine: offline(lidClosed: false))],
                settings: wifi).isEmpty)
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline(held: false)),
                 Poll(at: 300, machine: offline(held: false))],
                settings: wifi).isEmpty)
    // Already down when the lid closed: the drop happened with the person there.
    var openOffline = offline(lidClosed: false)
    openOffline.held = true
    #expect(run([Poll(at: 0, machine: openOffline), Poll(at: 1, machine: offline()),
                 Poll(at: 300, machine: offline())],
                settings: wifi).isEmpty)
    // The lid opening or the hold ending within the 60 s ends the episode,
    // and closing again with the network still down does not start one.
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline()),
                 Poll(at: 30, machine: offline(lidClosed: false)),
                 Poll(at: 31, machine: offline()), Poll(at: 300, machine: offline())],
                settings: wifi).isEmpty)
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline()),
                 Poll(at: 30, machine: offline(held: false)),
                 Poll(at: 31, machine: offline()), Poll(at: 300, machine: offline())],
                settings: wifi).isEmpty)
    // The first reading after launch is a baseline, not a drop.
    var unknown = heldClosed
    unknown.networkReachable = nil
    #expect(run([Poll(at: 0, machine: unknown), Poll(at: 1, machine: offline()),
                 Poll(at: 300, machine: offline())],
                settings: wifi).isEmpty)
}

@Test func wifiDroppedIsOffByDefault() {
    #expect(AlertSettings().wifiDropped == false)
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline()),
                 Poll(at: 300, machine: offline())]).isEmpty)
}

@Test func aReusedPIDIsADifferentHold() {
    // The first hold's process exited and its PID now runs a second hold.
    let first = AlertHold(HoldRecord(pid: 4182, label: "npm run build", startedAt: start))
    let second = AlertHold(HoldRecord(pid: 4182, label: "make",
                                      startedAt: start.addingTimeInterval(1320.5)))
    #expect(first.id != second.id)
    let alerts = run([
        Poll(at: 0, holds: [first]),
        Poll(at: 1320, holds: [first]),
        Poll(at: 1321, holds: [second]),
    ])
    #expect(alerts.map(\.title) == ["npm finished"])
}

@Test func aMonitoringLeaseRunningOutIsNotFinishing() {
    // Listed but no longer holding: neither Working, Waiting, nor Idle.
    let leaseEnded = session(wait: nil, stateChangedAt: start)
    #expect(run([
        Poll(at: 0, sessions: [working()]),
        Poll(at: 7200, sessions: [working()]),
        Poll(at: 7201, sessions: [leaseEnded]),
        Poll(at: 7300, sessions: [idle(since: 7300)]),
    ]).isEmpty)
}

@Test func aBareHoldSendsNoFinishedAlert() {
    // Ended by Ctrl-C in the terminal: the person is right there.
    let bare = AlertHold(HoldRecord(pid: 77, label: HoldRecord.terminalLabel, startedAt: start))
    #expect(run([
        Poll(at: 0, holds: [bare]),
        Poll(at: 1320, holds: [bare]),
        Poll(at: 1321),
    ]).isEmpty)
    let process = AlertHold(HoldRecord(pid: 78, label: HoldRecord.processLabel(pid: 4182),
                                       startedAt: start))
    #expect(run([
        Poll(at: 0, holds: [process]),
        Poll(at: 1320, holds: [process]),
        Poll(at: 1321),
    ]).map(\.title) == ["Process 4182 finished"])
}

// MARK: Manual sessions

/// The machine state the app derives from `decide()` when a menu manual
/// session is the only demand, lid closed.
private func manualSessionMachine(
    deadline: TimeInterval = 3_600,
    at offset: TimeInterval,
    power: PowerState = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal),
    networkReachable: Bool = true
) -> AlertMachineState {
    let decision = decide(
        sessions: [],
        demands: [.manualSession(deadline: start.addingTimeInterval(deadline))],
        now: start.addingTimeInterval(offset),
        settings: Settings(),
        power: power
    )
    return AlertMachineState(held: decision.holdSystem, holdWanted: !decision.wantedBy.isEmpty,
                             releasedBy: decision.releasedBy, lidClosed: true,
                             networkReachable: networkReachable)
}

@Test func manualSessionCountsAsSomethingThatWantedTheHold() {
    let hot = PowerState(onBattery: false, batteryPercent: 100, thermal: .serious)
    let stopped = run([
        Poll(at: 0, machine: manualSessionMachine(at: 0)),
        Poll(at: 1, machine: manualSessionMachine(at: 1, power: hot)),
    ])
    #expect(stopped.map(\.kind) == [.stoppedForPower])
    #expect(stopped.map(\.body) == ["It got too warm."])
    let low = PowerState(onBattery: true, batteryPercent: Settings().batteryFloor, thermal: .nominal)
    #expect(run([
        Poll(at: 0, machine: manualSessionMachine(at: 0)),
        Poll(at: 1, machine: manualSessionMachine(at: 1, power: low)),
    ]).map(\.body) == ["Battery reached \(Settings().batteryFloor)%."])

    var wifi = enabled
    wifi.wifiDropped = true
    #expect(run([
        Poll(at: 0, machine: manualSessionMachine(at: 0)),
        Poll(at: 1, machine: manualSessionMachine(at: 1, networkReachable: false)),
        Poll(at: 61, machine: manualSessionMachine(at: 61, networkReachable: false)),
    ], settings: wifi).map(\.kind) == [.wifiDropped])
}

@Test func manualSessionReachingItsDeadlineSendsNoAlert() {
    var all = enabled
    all.wifiDropped = true
    // The deadline lands as the Mac overheats and the network drops: the
    // session ended, nothing was stopped, and nothing is held for Wi-Fi.
    let hot = PowerState(onBattery: false, batteryPercent: 100, thermal: .serious)
    func polls(endingAt end: TimeInterval) -> [Poll] {
        [
            Poll(at: 0, machine: manualSessionMachine(deadline: 600, at: 0)),
            Poll(at: end, machine: manualSessionMachine(deadline: 600, at: end, power: hot,
                                                        networkReachable: false)),
        ]
    }
    #expect(run(polls(endingAt: 600), settings: all).isEmpty)
    // A second earlier, the session still wanted the hold.
    #expect(run(polls(endingAt: 599), settings: all).map(\.kind) == [.stoppedForPower])
}

// MARK: Phone destinations

private let phoneSetUp = AlertSettings(desktopAlerts: true, phoneAlerts: true)
private let waitedThirtySeconds: [(TimeInterval, [AlertSessionObservation])] = [
    (0, [session()]), (30, [session()]),
]

private func destinations(
    _ presence: AlertPresence,
    settings: AlertSettings = phoneSetUp
) -> Set<AlertDestination>? {
    run(waitedThirtySeconds, settings: settings, presence: presence).first?.destinations
}

private func idle(for seconds: TimeInterval) -> AlertPresence {
    AlertPresence(lidClosed: false, screenLocked: false, secondsSinceLastInput: seconds)
}

@Test func phoneAlertsGoOutOnlyWhenThePersonIsAway() {
    #expect(destinations(present) == [.desktop])
    #expect(destinations(AlertPresence(lidClosed: true, screenLocked: false, secondsSinceLastInput: 0))
        == [.desktop, .phone])
    #expect(destinations(AlertPresence(lidClosed: false, screenLocked: true, secondsSinceLastInput: 0))
        == [.desktop, .phone])
    #expect(destinations(idle(for: 300)) == [.desktop, .phone])
}

@Test func fiveMinutesWithoutInputIsTheAwayEdge() {
    #expect(destinations(idle(for: 299.9)) == [.desktop])
    #expect(destinations(idle(for: 300)) == [.desktop, .phone])
}

@Test func alwaysSendToPhoneIgnoresPresence() {
    var always = phoneSetUp
    always.alwaysSendToPhone = true
    #expect(destinations(present, settings: always) == [.desktop, .phone])
    #expect(AlertSettings().alwaysSendToPhone == false)
}

@Test func phoneAlertsAloneStillAlertWhenAway() {
    let phoneOnly = AlertSettings(desktopAlerts: false, phoneAlerts: true)
    #expect(destinations(idle(for: 600), settings: phoneOnly) == [.phone])
    // At the Mac with desktop alerts off there is nowhere to send.
    #expect(run(waitedThirtySeconds, settings: phoneOnly, presence: present).isEmpty)
}

@Test func noPhoneDestinationUnlessPhoneAlertsAreSetUp() {
    #expect(AlertSettings().phoneAlerts == false)
    var notSetUp = AlertSettings(desktopAlerts: true, alwaysSendToPhone: true)
    #expect(destinations(AlertPresence(lidClosed: true, screenLocked: true, secondsSinceLastInput: 900),
                         settings: notSetUp) == [.desktop])
    notSetUp.desktopAlerts = false
    #expect(run(waitedThirtySeconds, settings: notSetUp,
                presence: AlertPresence(lidClosed: true, screenLocked: true, secondsSinceLastInput: 900)).isEmpty)
}

@Test func aClosedLidOnADockedMacIsNotAway() {
    let docked = AlertPresence(lidClosed: true, screenLocked: false,
                               secondsSinceLastInput: 0, externalDisplay: true)
    #expect(!docked.isAway)
    #expect(destinations(docked) == [.desktop])
    // Docked, only a locked screen or five idle minutes count.
    #expect(AlertPresence(lidClosed: true, screenLocked: true,
                          secondsSinceLastInput: 0, externalDisplay: true).isAway)
    #expect(!AlertPresence(lidClosed: true, screenLocked: false,
                           secondsSinceLastInput: 299.9, externalDisplay: true).isAway)
    #expect(AlertPresence(lidClosed: true, screenLocked: false,
                          secondsSinceLastInput: 300, externalDisplay: true).isAway)
    // An external display with the lid open changes nothing.
    #expect(!AlertPresence(lidClosed: false, screenLocked: false,
                           secondsSinceLastInput: 0, externalDisplay: true).isAway)
}

// MARK: Phone follow-up when the person becomes away

private let lidClosed = AlertPresence(lidClosed: true, screenLocked: false, secondsSinceLastInput: 0)

@Test func becomingAwayInTheSameWaitSendsThePhoneTheAlertOnce() {
    let alerts = run([
        (0, [session()], present),
        (30, [session()], present),
        (45, [session()], present),
        (60, [session()], lidClosed),
        (75, [session()], lidClosed),
    ])
    #expect(alerts.map(\.destinations) == [[.desktop], [.phone]])
    #expect(alerts[1].id == alerts[0].id)
    #expect(alerts[1].title == alerts[0].title)
    #expect(alerts[1].body == alerts[0].body)
}

@Test func thePhoneFollowUpIsSentAtMostOncePerWait() {
    let alerts = run([
        (0, [session()], present), (30, [session()], present),
        (60, [session()], lidClosed), (90, [session()], present),
        (120, [session()], lidClosed), (150, [session()], idle(for: 900)),
    ])
    #expect(alerts.map(\.destinations) == [[.desktop], [.phone]])
}

@Test func noFollowUpWhenThePhoneAlreadyHadTheAlert() {
    let awayAtThirty = run([
        (0, [session()], present), (30, [session()], lidClosed),
        (60, [session()], present), (90, [session()], lidClosed),
    ])
    #expect(awayAtThirty.map(\.destinations) == [[.desktop, .phone]])

    var always = phoneSetUp
    always.alwaysSendToPhone = true
    let alwaysSent = run([
        (0, [session()], present), (30, [session()], present), (60, [session()], lidClosed),
    ], settings: always)
    #expect(alwaysSent.map(\.destinations) == [[.desktop, .phone]])
}

@Test func theFollowUpGoesOutEvenWhenNoDesktopAlertDid() {
    let phoneOnly = AlertSettings(desktopAlerts: false, phoneAlerts: true)
    let alerts = run([
        (0, [session()], present), (30, [session()], present), (60, [session()], lidClosed),
    ], settings: phoneOnly)
    #expect(alerts.map(\.destinations) == [[.phone]])
}

@Test func noFollowUpForAWaitAlreadyUnderWayAtLaunch() {
    #expect(run([(300, [session()], present), (330, [session()], lidClosed)]).isEmpty)
}

@Test func noFollowUpOnceTheWaitIsAnswered() {
    let alerts = run([
        (0, [session()], present), (30, [session()], present),
        (45, [session(wait: nil)], present), (60, [session(wait: nil)], lidClosed),
    ])
    #expect(alerts.map(\.destinations) == [[.desktop]])
}

@Test func eachWaitGetsItsOwnFollowUp() {
    let second = session(stateChangedAt: start.addingTimeInterval(100))
    let alerts = run([
        (0, [session()], present), (30, [session()], present),
        (60, [session()], lidClosed), (80, [session(wait: nil)], present),
        (100, [second], present), (130, [second], present), (160, [second], lidClosed),
    ])
    #expect(alerts.map(\.destinations) == [[.desktop], [.phone], [.desktop], [.phone]])
    #expect(alerts[1].id != alerts[3].id)
}

@Test func noFollowUpUnlessPhoneAlertsAreWorkingAndNeedsYouIsOn() {
    let desktopOnly = AlertSettings(desktopAlerts: true)
    #expect(run([
        (0, [session()], present), (30, [session()], present), (60, [session()], lidClosed),
    ], settings: desktopOnly).map(\.destinations) == [[.desktop]])

    var needsYouOff = phoneSetUp
    needsYouOff.needsYou = false
    #expect(run([
        (0, [session()], present), (30, [session()], present), (60, [session()], lidClosed),
    ], settings: needsYouOff).isEmpty)
}

@Test func eachWaitingSessionGetsItsOwnFollowUp() {
    let other = session("s2", project: "other")
    let alerts = run([
        (0, [session(), other], present), (30, [session(), other], present),
        (60, [session(), other], lidClosed),
    ])
    let phone = alerts.filter { $0.destinations == [.phone] }
    #expect(Set(phone.map(\.sessionID)) == ["s1", "s2"])
}

@Test func theFollowUpWaitsForTheFiveMinuteIdleEdge() {
    let steps: (AlertPresence) -> [(TimeInterval, [AlertSessionObservation], AlertPresence)] = {
        [(0, [session()], present), (30, [session()], present), (60, [session()], $0)]
    }
    #expect(run(steps(idle(for: 299.9))).count == 1)
    #expect(run(steps(idle(for: 300))).map(\.destinations) == [[.desktop], [.phone]])
}

@Test func unpluggingTheDisplayOfAClosedMacCountsAsBecomingAway() {
    let docked = AlertPresence(lidClosed: true, screenLocked: false,
                               secondsSinceLastInput: 0, externalDisplay: true)
    let alerts = run([
        (0, [session()], docked), (30, [session()], docked),
        (60, [session()], docked), (90, [session()], lidClosed),
    ])
    #expect(alerts.map(\.destinations) == [[.desktop], [.phone]])
}

@Test func lockingTheScreenLaterSendsTheFollowUp() {
    let locked = AlertPresence(lidClosed: false, screenLocked: true, secondsSinceLastInput: 0)
    let alerts = run([
        (0, [session()], present), (30, [session()], present), (40, [session()], locked),
    ])
    #expect(alerts.map(\.destinations) == [[.desktop], [.phone]])
}

// MARK: Every alert type on the phone

private let screenLocked = AlertPresence(lidClosed: false, screenLocked: true, secondsSinceLastInput: 0)

/// Polls that send exactly one alert of each type other than needs-you.
private let eachOtherKind: [(AlertKind, [Poll])] = [
    (.finished, [Poll(at: 0, sessions: [working()]), Poll(at: 200, sessions: [idle(since: 200)])]),
    (.finished, [Poll(at: 0, holds: [hold()]), Poll(at: 1321, ended: [ended(after: 22, status: 1)])]),
    (.stoppedForPower, [Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: released(.thermal))]),
    (.wifiDropped, [
        Poll(at: 0, machine: heldClosed),
        Poll(at: 10, machine: offline()),
        Poll(at: 70, machine: offline()),
    ]),
]

private let everyType = AlertSettings(desktopAlerts: true, wifiDropped: true, phoneAlerts: true)

@Test func everyAlertTypeGoesToThePhoneOnlyWhenAway() {
    for (kind, polls) in eachOtherKind {
        let atTheMac = run(polls, settings: everyType)
        let away = run(polls, settings: everyType, presence: screenLocked)
        #expect(atTheMac.map(\.kind) == [kind])
        #expect(atTheMac.map(\.destinations) == [[.desktop]])
        #expect(away.map(\.destinations) == [[.desktop, .phone]])
        // The phone gets the desktop's words.
        #expect(away.map(\.title) == atTheMac.map(\.title))
        #expect(away.map(\.body) == atTheMac.map(\.body))
    }
}

@Test func everyAlertTypeFollowsAlwaysSendAndPhoneOnly() {
    var always = everyType
    always.alwaysSendToPhone = true
    var phoneOnly = everyType
    phoneOnly.desktopAlerts = false
    let docked = AlertPresence(lidClosed: true, screenLocked: false,
                               secondsSinceLastInput: 0, externalDisplay: true)
    for (_, polls) in eachOtherKind {
        #expect(run(polls, settings: always).map(\.destinations) == [[.desktop, .phone]])
        #expect(run(polls, settings: phoneOnly).isEmpty)
        #expect(run(polls, settings: phoneOnly, presence: screenLocked).map(\.destinations) == [[.phone]])
        #expect(run(polls, settings: phoneOnly, presence: lidClosed).map(\.destinations) == [[.phone]])
        #expect(run(polls, settings: phoneOnly, presence: docked).isEmpty)
    }
}

@Test func onlyANeedsYouWaitGetsALaterPhoneFollowUp() {
    // An event that alerted at the Mac is not resent on becoming away.
    for (_, polls) in eachOtherKind {
        var later = polls.last!
        later.at += 60
        later.ended = []
        later.presence = screenLocked
        #expect(run(polls + [later], settings: everyType).map(\.destinations) == [[.desktop]])
    }
}
