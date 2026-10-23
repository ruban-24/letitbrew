import Testing
import Foundation
@testable import LetItBrewCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func session(
    _ state: SessionState,
    detail: String? = nil,
    idleFor seconds: TimeInterval = 0
) -> SessionRecord {
    SessionRecord(id: UUID().uuidString, tool: "claude", state: state, detail: detail,
                  cwd: "/tmp/repo", pid: 1, updatedAt: now.addingTimeInterval(-seconds))
}

private let plugged = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)

@Test func onlyWorkingSessionsHold() {
    let decision = decide(
        sessions: [session(.working), session(.idle)],
        now: now,
        settings: Settings(),
        power: plugged
    )
    #expect(decision.holdSystem)
    #expect(decision.holdLidClosed)
    #expect(decision.reason == "1 working")
}

@Test func allIdleSessionsReleaseImmediately() {
    let decision = decide(
        sessions: [session(.idle), session(.idle)],
        now: now,
        settings: Settings(),
        power: plugged
    )
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(decision.reason == "all agents idle")
}

@Test func idleSessionsReleaseWithoutGrace() {
    for idleFor in [0.0, 0.1, 300.0] {
        let decision = decide(sessions: [session(.idle, idleFor: idleFor)],
                              now: now, settings: Settings(), power: plugged)
        #expect(!decision.holdSystem)
        #expect(!decision.holdLidClosed)
        #expect(decision.reason == "all agents idle")
    }
}

@Test func noSessionsMeansNoHold() {
    let decision = decide(sessions: [], now: now, settings: Settings(), power: plugged)
    #expect(!decision.holdSystem)
    #expect(decision.reason == "no agent sessions")
}

@Test func lowBatteryOverridesWorkingAgents() {
    let power = PowerState(onBattery: true, batteryPercent: 15, thermal: .nominal)
    let decision = decide(sessions: [session(.working)], now: now,
                          settings: Settings(), power: power)
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(decision.reason == "battery 15%")
}

@Test func safetyOverridesWorkingAgents() {
    let working = session(.working)
    let lowBattery = PowerState(onBattery: true, batteryPercent: 20, thermal: .nominal)
    let tooWarm = PowerState(onBattery: false, batteryPercent: 100, thermal: .serious)
    let unknown = PowerState(
        onBattery: false,
        batteryPercent: 100,
        thermal: .nominal,
        trusted: false
    )

    #expect(!decide(sessions: [working], now: now, settings: Settings(), power: lowBattery).holdSystem)
    #expect(!decide(sessions: [working], now: now, settings: Settings(), power: tooWarm).holdSystem)
    #expect(!decide(sessions: [working], now: now, settings: Settings(), power: unknown).holdSystem)
}

@Test func lowBatteryOnACDoesNotRelease() {
    let power = PowerState(onBattery: false, batteryPercent: 15, thermal: .nominal)
    #expect(decide(sessions: [session(.working)], now: now,
                   settings: Settings(), power: power).holdSystem)
}

@Test func batteryAtTheFloorReleases() {
    // The user-facing threshold says release "at" this level.
    let power = PowerState(onBattery: true, batteryPercent: 20, thermal: .nominal)
    let decision = decide(sessions: [session(.working)], now: now,
                          settings: Settings(), power: power)
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(decision.reason == "battery 20%")
}

@Test func thermalPressureOverridesWorkingAgents() {
    // A shut lid with no external display traps heat with no airflow.
    for state in [ProcessInfo.ThermalState.serious, .critical] {
        let power = PowerState(onBattery: false, batteryPercent: 100, thermal: state)
        let decision = decide(sessions: [session(.working)], now: now,
                              settings: Settings(), power: power)
        #expect(!decision.holdSystem)
        #expect(decision.reason == "thermal pressure")
    }
}

@Test func fairThermalStateStillHolds() {
    let power = PowerState(onBattery: false, batteryPercent: 100, thermal: .fair)
    #expect(decide(sessions: [session(.working)], now: now,
                   settings: Settings(), power: power).holdSystem)
}

@Test func batteryOutranksThermalInTheReason() {
    let power = PowerState(onBattery: true, batteryPercent: 5, thermal: .critical)
    let decision = decide(sessions: [session(.working)], now: now,
                          settings: Settings(), power: power)
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(decision.reason == "battery 5%")
}

// MARK: - Important 4: an untrusted power reading must never bypass the floor

@Test func untrustedBatteryReadingRefusesToHoldEvenWhenReportedAsPluggedIn() {
    // Before this fix, an IOKit failure surfaced as `onBattery: false,
    // batteryPercent: 100` — indistinguishable from a confirmed desktop —
    // which would sail straight past the battery-floor check below and hold
    // a laptop awake on a battery reading nothing actually confirmed.
    let untrusted = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal, trusted: false)
    let decision = decide(sessions: [session(.working)], now: now, settings: Settings(), power: untrusted)
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(decision.reason == "battery state unknown")
}

@Test func untrustedReadingTakesPrecedenceOverEverythingElse() {
    // The conservative branch must win even over an otherwise-clear-cut
    // "hold" case (working session, comfortable thermal state) — an unknown
    // battery reading is the one thing this fix refuses to guess past.
    let untrusted = PowerState(onBattery: true, batteryPercent: 90, thermal: .nominal, trusted: false)
    let decision = decide(
        sessions: [session(.working), session(.idle)], now: now, settings: Settings(), power: untrusted)
    #expect(!decision.holdSystem)
    #expect(decision.reason == "battery state unknown")
}

@Test func trustedReadingsAreCompletelyUnaffectedByTheNewField() {
    // The default (`trusted: true`, matching every OTHER test in this file
    // that constructs `PowerState` without naming it) must behave exactly as
    // before.
    #expect(plugged.trusted)
    let decision = decide(sessions: [session(.working)], now: now, settings: Settings(), power: plugged)
    #expect(decision.holdSystem)
}

@Test func lidHoldFollowsTheSettingNotTheSession() {
    var settings = Settings()
    settings.lidClosedFollowsSession = false
    let decision = decide(sessions: [session(.working)], now: now,
                          settings: settings, power: plugged)
    #expect(decision.holdSystem)
    #expect(!decision.holdLidClosed)
}

@Test func connectedPowerOnlyReleasesOnBattery() {
    var settings = Settings()
    settings.onlyWhileConnectedToPower = true
    let power = PowerState(
        onBattery: true,
        batteryPercent: 90,
        thermal: .nominal
    )
    let decision = decide(
        sessions: [session(.working)], now: now,
        settings: settings, power: power
    )
    #expect(!decision.holdSystem)
    #expect(!decision.holdLidClosed)
    #expect(!decision.holdDisplay)
    #expect(decision.reason == "battery power")
}

@Test func connectedPowerOnlyOutranksBatteryFloor() {
    var settings = Settings()
    settings.onlyWhileConnectedToPower = true
    let decision = decide(
        sessions: [session(.working)], now: now,
        settings: settings,
        power: PowerState(onBattery: true, batteryPercent: 20, thermal: .nominal)
    )
    #expect(decision.reason == "battery power")
}

@Test func respectedLowPowerModeReleasesOnACAndBattery() {
    var settings = Settings()
    #expect(!settings.respectLowPowerMode)
    settings.respectLowPowerMode = true
    for onBattery in [false, true] {
        let power = PowerState(
            onBattery: onBattery,
            batteryPercent: 90,
            thermal: .nominal,
            lowPowerModeEnabled: true
        )
        let decision = decide(
            sessions: [session(.working)], now: now,
            settings: settings, power: power
        )
        #expect(!decision.holdSystem)
        #expect(decision.reason == "low power mode")
    }
}

@Test func displayIntentIsIndependentFromSystemHold() {
    var settings = Settings()
    settings.allowDisplaysToSleep = false
    let awake = decide(
        sessions: [session(.working)], now: now,
        settings: settings, power: plugged
    )
    #expect(awake.holdSystem)
    #expect(awake.holdDisplay)

    settings.allowDisplaysToSleep = true
    let displaySleepAllowed = decide(
        sessions: [session(.working)], now: now,
        settings: settings, power: plugged
    )
    #expect(displaySleepAllowed.holdSystem)
    #expect(!displaySleepAllowed.holdDisplay)
}

@Test func lowPowerModeLetItBrewTurnedOnDoesNotReleaseItsOwnHold() {
    var settings = Settings()
    settings.respectLowPowerMode = true
    let power = PowerState(
        onBattery: true, batteryPercent: 90, thermal: .nominal, lowPowerModeEnabled: true
    )
    let owned = decide(
        sessions: [session(.working)], now: now, settings: settings, power: power,
        lowPowerModeOwnedByLetItBrew: true
    )
    #expect(owned.holdSystem)
    #expect(owned.holdLidClosed)

    let personal = decide(
        sessions: [session(.working)], now: now, settings: settings, power: power,
        lowPowerModeOwnedByLetItBrew: false
    )
    #expect(!personal.holdSystem)
    #expect(personal.reason == "low power mode")
}

@Test func ownedLowPowerModeNeverBypassesTheOtherSafetyGates() {
    var settings = Settings()
    settings.respectLowPowerMode = true
    let low = PowerState(
        onBattery: true, batteryPercent: 10, thermal: .nominal, lowPowerModeEnabled: true
    )
    #expect(!decide(
        sessions: [session(.working)], now: now, settings: settings, power: low,
        lowPowerModeOwnedByLetItBrew: true
    ).holdSystem)
    let hot = PowerState(
        onBattery: false, batteryPercent: 100, thermal: .serious, lowPowerModeEnabled: true
    )
    #expect(!decide(
        sessions: [session(.working)], now: now, settings: settings, power: hot,
        lowPowerModeOwnedByLetItBrew: true
    ).holdSystem)
}

private func waiting(
    _ detail: String = SessionWaitDetail.approval,
    tool: AgentID = .claude,
    since: Date = now.addingTimeInterval(-60),
    id: String = UUID().uuidString,
    transition: String = "wait-1"
) -> SessionRecord {
    var record = SessionRecord(
        id: id, tool: tool.rawValue, state: .waiting, detail: detail,
        cwd: "/tmp/repo", pid: 1, updatedAt: since
    )
    record.stateChangedAt = since
    record.stateTransitionID = transition
    return record
}

private func answers(
    _ sessions: [SessionRecord],
    input: UserInputObservation
) -> WaitAnswerLatch {
    .observing(sessions, input: input)
}

@Test func waitingSessionsReleaseWithoutInput() {
    for detail in [SessionWaitDetail.question, SessionWaitDetail.approval] {
        let sessions = [waiting(detail)]
        let decision = decide(
            sessions: sessions, now: now, settings: Settings(), power: plugged,
            waitAnswers: answers(sessions, input: .lastInput(at: now.addingTimeInterval(-600)))
        )
        #expect(!decision.holdSystem)
        #expect(!decision.holdLidClosed)
        #expect(decision.reason == "agents waiting for you")
    }
    // Callers that observe no input default to releasing.
    #expect(!decide(
        sessions: [waiting()], now: now, settings: Settings(), power: plugged
    ).holdSystem)
}

@Test func inputAfterAWaitBeganHoldsUntilTheNextHook() {
    let since = now.addingTimeInterval(-60)
    let sessions = [waiting(SessionWaitDetail.approval, since: since)]
    let answered = decide(
        sessions: sessions, now: now, settings: Settings(), power: plugged,
        waitAnswers: answers(sessions, input: .lastInput(at: since.addingTimeInterval(30)))
    )
    #expect(answered.holdSystem)
    #expect(answered.holdLidClosed)
    #expect(answered.reason == "1 working")
}

@Test func inputJustBeforeAClaudePermissionNotificationStillCounts() {
    let since = now.addingTimeInterval(-60)
    let tolerance = WaitAnswerLatch.answerLeadTolerance
    var notified = waiting(SessionWaitDetail.approval, since: since)
    notified.lastEvent = "Notification"
    let sessions = [notified]
    #expect(decide(
        sessions: sessions, now: now, settings: Settings(), power: plugged,
        waitAnswers: answers(sessions, input: .lastInput(at: since.addingTimeInterval(-tolerance)))
    ).holdSystem)
    #expect(!decide(
        sessions: sessions, now: now, settings: Settings(), power: plugged,
        waitAnswers: answers(
            sessions, input: .lastInput(at: since.addingTimeInterval(-tolerance - 1))
        )
    ).holdSystem)
}

@Test func copilotPromptsKeepOnlyASmallLeadForHookDelivery() {
    let since = now.addingTimeInterval(-60)
    var wait = waiting(tool: .copilot, since: since)
    wait.lastEvent = "Notification"
    wait.eventObservedAt = since.timeIntervalSince1970 + 0.8
    let notified = Date(timeIntervalSince1970: wait.eventObservedAt!)
    let lead = WaitAnswerLatch.copilotAnswerLeadTolerance
    func holds(_ input: Date) -> Bool {
        decide(
            sessions: [wait], now: now, settings: Settings(), power: plugged,
            waitAnswers: answers([wait], input: .lastInput(at: input))
        ).holdSystem
    }
    // An answer just before the hook landed still counts.
    #expect(holds(notified.addingTimeInterval(-lead)))
    // The Enter that submitted the turn seconds earlier does not.
    #expect(!holds(notified.addingTimeInterval(-lead - 0.5)))
    #expect(holds(since.addingTimeInterval(2)))
}

@Test func waitsWhoseAnswerSendsAHookNeverConsultInput() {
    let since = now.addingTimeInterval(-60)
    let reported: [(AgentID, String)] = [
        (.claude, SessionWaitDetail.question), (.codex, SessionWaitDetail.question),
        (.copilot, SessionWaitDetail.question), (.opencode, SessionWaitDetail.question),
        (.opencode, SessionWaitDetail.approval), (.pi, SessionWaitDetail.question),
    ]
    for (tool, detail) in reported {
        let sessions = [waiting(detail, tool: tool, since: since)]
        for input in [UserInputObservation.unavailable, .lastInput(at: since.addingTimeInterval(5))] {
            let latch = answers(sessions, input: input)
            #expect(!latch.mayHaveBeenAnswered(sessions[0]), "\(tool) \(detail)")
            #expect(!decide(
                sessions: sessions, now: now, settings: Settings(), power: plugged,
                waitAnswers: latch
            ).holdSystem)
        }
    }
    for tool in [AgentID.claude, .copilot] {
        #expect(WaitAnswerLatch.answerIsSilent(waiting(tool: tool)))
    }
}

@Test func eachSilentWaitConsultsItsOwnInput() {
    let since = now.addingTimeInterval(-60)
    let inTerminal = waiting(since: since, id: "terminal")
    let inEditor = waiting(since: since, id: "editor")
    var latch = WaitAnswerLatch()
    latch.observe([inTerminal, inEditor]) { wait in
        wait.id == "terminal" ? .lastInput(at: since.addingTimeInterval(5)) : .none
    }
    #expect(latch.holdsAwake(inTerminal))
    #expect(!latch.holdsAwake(inEditor))
}

@Test func anUnreadableInputCounterKeepsWaitsHeld() {
    let sessions = [waiting()]
    #expect(decide(
        sessions: sessions, now: now, settings: Settings(), power: plugged,
        waitAnswers: answers(sessions, input: .unavailable)
    ).holdSystem)
}

@Test func answeredWaitsStillYieldToSafetyGates() {
    let lowBattery = PowerState(onBattery: true, batteryPercent: 5, thermal: .nominal)
    let sessions = [waiting()]
    #expect(!decide(
        sessions: sessions, now: now, settings: Settings(), power: lowBattery,
        waitAnswers: answers(sessions, input: .unavailable)
    ).holdSystem)
}

@Test func workingSessionsHoldRegardlessOfInput() {
    let sessions = [session(.working), waiting()]
    let decision = decide(
        sessions: sessions, now: now, settings: Settings(), power: plugged,
        waitAnswers: answers(sessions, input: .none)
    )
    #expect(decision.holdSystem)
    #expect(decision.reason == "1 working")
}

@Test func theLatchKeepsAnAnswerAfterLaterInputIsDiscarded() {
    let since = now.addingTimeInterval(-60)
    let sessions = [waiting(since: since)]
    var latch = WaitAnswerLatch()
    latch.observe(sessions, input: .lastInput(at: since.addingTimeInterval(5)))
    // The next poll's only input was discarded, so it reports none.
    latch.observe(sessions, input: .none)
    #expect(latch.holdsAwake(sessions[0]))
}

@Test func theLatchForgetsEndedWaitsAndTreatsANewWaitAsUnanswered() {
    let since = now.addingTimeInterval(-60)
    let first = waiting(since: since, id: "s", transition: "wait-1")
    var latch = WaitAnswerLatch()
    latch.observe([first], input: .lastInput(at: since.addingTimeInterval(5)))
    #expect(latch.mayHaveBeenAnswered(first))

    let second = waiting(since: since.addingTimeInterval(30), id: "s", transition: "wait-2")
    latch.observe([second], input: .lastInput(at: since.addingTimeInterval(5)))
    #expect(!latch.mayHaveBeenAnswered(second))

    // The first wait's key was forgotten, so its return is not pre-answered.
    latch.observe([first], input: .none)
    #expect(!latch.mayHaveBeenAnswered(first))
}

@Test func anUnavailableReadingRecoversWhenTheCounterReturns() {
    let sessions = [waiting()]
    var latch = WaitAnswerLatch()
    latch.observe(sessions, input: .unavailable)
    #expect(latch.holdsAwake(sessions[0]))
    latch.observe(sessions, input: .none)
    #expect(!latch.holdsAwake(sessions[0]))
}

@Test func theLatchNeverChangesWorkingOrIdleSessions() {
    let latch = WaitAnswerLatch.observing([], input: .unavailable)
    #expect(latch.holdsAwake(session(.working)))
    #expect(!latch.holdsAwake(session(.idle)))
    #expect(!latch.mayHaveBeenAnswered(session(.working)))
}

// MARK: - The monitoring lease

private func familyID(_ parent: String, child: String? = nil) -> String {
    HookRecordID(agent: .claude, parentID: parent, childID: child)!.encoded
}

private func monitoring(
    ageSeconds: TimeInterval,
    detail: String? = SessionWorkDetail.backgroundShell,
    id: String = UUID().uuidString,
    state: SessionState = .working,
    lastEvent: String = "Stop"
) -> SessionRecord {
    SessionRecord(id: id, tool: "claude", state: state, detail: detail,
                  cwd: "/tmp/repo", pid: 1, updatedAt: now.addingTimeInterval(-ageSeconds),
                  lastEvent: lastEvent, stateChangedAt: now.addingTimeInterval(-9_000))
}

@Test func monitoringHoldsUntilItsFamilyHasBeenSilentForTheLimit() {
    let settings = Settings()
    #expect(settings.monitoringHoldLimit == 7_200)
    for detail in [SessionWorkDetail.backgroundShell, SessionWorkDetail.backgroundAgent,
                   SessionWorkDetail.scheduledTasks] {
        for age in [0.0, 60, 7_199] {
            let decision = decide(sessions: [monitoring(ageSeconds: age, detail: detail)],
                                  now: now, settings: settings, power: plugged)
            #expect(decision.holdSystem, "\(detail) age \(age)")
            #expect(decision.reason == "1 working")
        }
        for age in [7_200.0, 7_201, 40_000] {
            let decision = decide(sessions: [monitoring(ageSeconds: age, detail: detail)],
                                  now: now, settings: settings, power: plugged)
            #expect(!decision.holdSystem, "\(detail) age \(age)")
            #expect(!decision.holdLidClosed)
            #expect(decision.reason == "monitoring hold expired")
        }
    }
}

@Test func monitoringMeasuresFromTheLatestEdgeNotTheTurnStart() {
    // stateChangedAt is older than the limit in the fixture; only edges count.
    let decision = decide(sessions: [monitoring(ageSeconds: 10)], now: now,
                          settings: Settings(), power: plugged)
    #expect(decision.holdSystem)
}

@Test func anyHookInTheFamilyRenewsTheLease() {
    let parent = monitoring(ageSeconds: 9_000, detail: SessionWorkDetail.backgroundAgent,
                            id: familyID("parent"))
    // A subagent of the same session reported a moment ago.
    let child = monitoring(ageSeconds: 10, detail: "running-command",
                           id: familyID("parent", child: "helper"), lastEvent: "PostToolUse")
    let decision = decide(sessions: [parent, child], now: now,
                          settings: Settings(), power: plugged)
    #expect(decision.holdSystem)
    #expect(decision.reason == "2 working")

    // Another session's activity does not renew it.
    let stranger = monitoring(ageSeconds: 10, detail: nil, id: familyID("other"),
                              state: .idle, lastEvent: "Stop")
    let alone = decide(sessions: [parent, stranger], now: now,
                       settings: Settings(), power: plugged)
    #expect(!alone.holdSystem)
    #expect(alone.reason == "monitoring hold expired")
}

@Test func aSilentSubagentRecordStopsHoldingAtTheLimit() {
    let parent = monitoring(ageSeconds: 7_300, detail: nil, id: familyID("parent"),
                            state: .idle, lastEvent: "Notification")
    let child = monitoring(ageSeconds: 7_300, detail: "running-command",
                           id: familyID("parent", child: "killed"), lastEvent: "PreToolUse")
    let quiet = decide(sessions: [parent, child], now: now, settings: Settings(), power: plugged)
    #expect(!quiet.holdSystem)
    #expect(quiet.reason == "monitoring hold expired")

    // The parent being heard from keeps its subagent's record holding.
    let renewed = monitoring(ageSeconds: 5, detail: nil, id: familyID("parent"),
                             state: .idle, lastEvent: "Notification")
    #expect(decide(sessions: [renewed, child], now: now,
                   settings: Settings(), power: plugged).holdSystem)
}

@Test func aForegroundTurnIsNeverLeased() {
    for detail in [nil, "running-command"] {
        let turn = monitoring(ageSeconds: 50_000, detail: detail, lastEvent: "PreToolUse")
        let decision = decide(sessions: [turn], now: now, settings: Settings(), power: plugged)
        #expect(decision.holdSystem, "detail \(detail ?? "nil")")
    }
}

@Test func anExpiredLeaseDoesNotMaskOtherWorkOrWaits() {
    let working = decide(sessions: [monitoring(ageSeconds: 9_000), session(.working)], now: now,
                         settings: Settings(), power: plugged)
    #expect(working.holdSystem)
    #expect(working.reason == "1 working")

    let waiting = decide(sessions: [monitoring(ageSeconds: 9_000), session(.waiting)], now: now,
                         settings: Settings(), power: plugged)
    #expect(!waiting.holdSystem)
    #expect(waiting.reason == "agents waiting for you")
}

@Test func aNonPositiveOrInfiniteLimitNeverExpiresALease() {
    for limit in [0.0, -1, .infinity, .nan] {
        var settings = Settings()
        settings.monitoringHoldLimit = limit
        let decision = decide(sessions: [monitoring(ageSeconds: 90_000)], now: now,
                              settings: settings, power: plugged)
        #expect(decision.holdSystem, "limit \(limit)")
    }
}
