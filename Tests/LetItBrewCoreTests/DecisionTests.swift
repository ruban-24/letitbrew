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

@Test func respectedLowPowerModeReleasesOnACAndBattery() {
    for onBattery in [false, true] {
        let power = PowerState(
            onBattery: onBattery,
            batteryPercent: 90,
            thermal: .nominal,
            lowPowerModeEnabled: true
        )
        let decision = decide(
            sessions: [session(.working)], now: now,
            settings: Settings(), power: power
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
