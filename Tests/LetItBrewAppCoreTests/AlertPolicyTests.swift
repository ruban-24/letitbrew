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

private func run(_ polls: [Poll], settings: AlertSettings = enabled) -> [Alert] {
    var previous: AlertSnapshot?
    var alerts: [Alert] = []
    for poll in polls {
        let current = AlertSnapshot(
            observedAt: start.addingTimeInterval(poll.at),
            sessions: poll.sessions,
            holds: poll.holds,
            endedHolds: poll.ended,
            machine: poll.machine,
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
    #expect(succeeded.map(\.title) == ["npm run build finished"])
    #expect(succeeded.map(\.body) == ["Succeeded after 22 min"])
    #expect(succeeded.first?.agentPID == nil)

    let failed = run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 361, ended: [ended(after: 6, status: 1)]),
    ])
    #expect(failed.map(\.title) == ["npm run build failed"])
    #expect(failed.map(\.body) == ["Failed after 6 min"])

    // Ended by a signal (128 + signal) is a failure too.
    #expect(run([
        Poll(at: 0, holds: [hold()]),
        Poll(at: 361, ended: [ended(after: 6, status: 130)]),
    ]).map(\.title) == ["npm run build failed"])
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

@Test func wifiDroppedAlertsWhenTheNetworkGoesWhileClosedAndHeld() {
    var wifi = enabled
    wifi.wifiDropped = true
    let alerts = run([
        Poll(at: 0, machine: heldClosed),
        Poll(at: 1, machine: offline()),
        Poll(at: 2, machine: offline()),
        Poll(at: 300, machine: offline()),
    ], settings: wifi)
    #expect(alerts.map(\.kind) == [.wifiDropped])
    #expect(alerts.map(\.title) == ["Wi-Fi dropped while your Mac was closed"])
    #expect(alerts.map(\.body) == ["Agents may be stuck until it reconnects."])

    // Back, then gone again: a second episode.
    #expect(run([
        Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline()),
        Poll(at: 2, machine: heldClosed), Poll(at: 3, machine: offline()),
    ], settings: wifi).count == 2)
}

@Test func wifiDroppedNeedsTheLidClosedAndSomethingHeld() {
    var wifi = enabled
    wifi.wifiDropped = true
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline(lidClosed: false))],
                settings: wifi).isEmpty)
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline(held: false))],
                settings: wifi).isEmpty)
    // Already down when the lid closed: the drop happened with the person there.
    var openOffline = offline(lidClosed: false)
    openOffline.held = true
    #expect(run([Poll(at: 0, machine: openOffline), Poll(at: 1, machine: offline())],
                settings: wifi).isEmpty)
    // The first reading after launch is a baseline, not a drop.
    var unknown = heldClosed
    unknown.networkReachable = nil
    #expect(run([Poll(at: 0, machine: unknown), Poll(at: 1, machine: offline())],
                settings: wifi).isEmpty)
}

@Test func wifiDroppedIsOffByDefault() {
    #expect(AlertSettings().wifiDropped == false)
    #expect(run([Poll(at: 0, machine: heldClosed), Poll(at: 1, machine: offline())]).isEmpty)
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
    #expect(alerts.map(\.title) == ["npm run build finished"])
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
