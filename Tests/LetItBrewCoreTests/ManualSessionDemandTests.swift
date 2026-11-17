import Foundation
import Testing
@testable import LetItBrewCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let plugged = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)

@Test func manualSessionKeepsTheMacAwakeWithNoAgents() {
    var settings = Settings()
    settings.allowDisplaysToSleep = false
    let decision = decide(sessions: [], demands: [.manualSession(deadline: now.addingTimeInterval(60))],
                          now: now, settings: settings, power: plugged)
    #expect(decision.holdSystem)
    #expect(decision.holdLidClosed)
    #expect(decision.holdDisplay)
    #expect(decision.reason == "manual session")
    #expect(decision.wantedBy == HoldDemandCount(manualSessions: 1))
}

@Test func indefiniteManualSessionHoldsUntilEnded() {
    let decision = decide(sessions: [], demands: [.manualSession(deadline: nil)],
                          now: now.addingTimeInterval(30 * 86_400),
                          settings: Settings(), power: plugged)
    #expect(decision.holdSystem)
    #expect(decision.reason == "manual session")
}

@Test func manualSessionStopsHoldingAtItsDeadline() {
    let deadline = now.addingTimeInterval(60)
    let before = decide(sessions: [], demands: [.manualSession(deadline: deadline)],
                        now: deadline.addingTimeInterval(-0.5), settings: Settings(), power: plugged)
    #expect(before.holdSystem)

    for late in [deadline, deadline.addingTimeInterval(1)] {
        let decision = decide(sessions: [], demands: [.manualSession(deadline: deadline)],
                              now: late, settings: Settings(), power: plugged)
        #expect(!decision.holdSystem)
        #expect(!decision.holdLidClosed)
        #expect(decision.wantedBy.isEmpty)
        #expect(decision.reason == "no agent sessions")
    }
}

@Test func manualSessionFollowsTheClosedLidSettingLikeAgents() {
    var settings = Settings()
    settings.lidClosedFollowsSession = false
    let decision = decide(sessions: [], demands: [.manualSession(deadline: nil)], now: now,
                          settings: settings, power: plugged)
    #expect(decision.holdSystem)
    #expect(!decision.holdLidClosed)
}

@Test func manualSessionCombinesWithAgentsAndHolds() {
    let working = SessionRecord(id: "a", tool: "claude", state: .working, detail: nil,
                                cwd: "/tmp/repo", pid: 1, updatedAt: now)
    let idle = SessionRecord(id: "b", tool: "codex", state: .idle, detail: nil,
                             cwd: "/tmp/repo", pid: 2, updatedAt: now)
    let hold = HoldRecord(pid: 3, label: "make", startedAt: now)
    let decision = decide(
        sessions: [working, idle],
        demands: [.hold(hold), .manualSession(deadline: nil)],
        now: now, settings: Settings(), power: plugged
    )
    #expect(decision.holdSystem)
    #expect(decision.reason == "1 working, manual session, 1 hold")
    #expect(decision.wantedBy == HoldDemandCount(agents: 1, holds: 1, manualSessions: 1))

    // An agent going idle leaves the session's hold in place.
    let agentsIdle = decide(sessions: [idle], demands: [.manualSession(deadline: nil)],
                            now: now, settings: Settings(), power: plugged)
    #expect(agentsIdle.holdSystem)
    #expect(agentsIdle.reason == "manual session")
}

@Test func manualSessionIsNeverBoundByTheMonitoringLimit() {
    var settings = Settings()
    settings.monitoringHoldLimit = 60
    let decision = decide(sessions: [], demands: [.manualSession(deadline: nil)],
                          now: now, settings: settings, power: plugged)
    #expect(decision.holdSystem)
}

/// Each power rule releases a manual session, in the same priority order as
/// agents, and still reports that the session wanted the Mac awake.
@Test func powerRulesReleaseManualSessionsInPriorityOrder() {
    var settings = Settings()
    settings.onlyWhileConnectedToPower = true
    settings.respectLowPowerMode = true
    let cases: [(PowerState, String)] = [
        (PowerState(onBattery: true, batteryPercent: 10, thermal: .critical,
                    lowPowerModeEnabled: true, trusted: false), "battery state unknown"),
        (PowerState(onBattery: true, batteryPercent: 10, thermal: .critical,
                    lowPowerModeEnabled: true), "battery power"),
        (PowerState(onBattery: false, batteryPercent: 10, thermal: .critical,
                    lowPowerModeEnabled: true), "low power mode"),
        (PowerState(onBattery: false, batteryPercent: 100, thermal: .serious),
         "thermal pressure"),
    ]
    for (power, reason) in cases {
        let decision = decide(sessions: [], demands: [.manualSession(deadline: nil)], now: now,
                              settings: settings, power: power)
        #expect(!decision.holdSystem)
        #expect(!decision.holdLidClosed)
        #expect(decision.reason == reason)
        #expect(decision.wantedBy == HoldDemandCount(manualSessions: 1))
    }

    settings.onlyWhileConnectedToPower = false
    let floor = decide(
        sessions: [], demands: [.manualSession(deadline: nil)], now: now, settings: settings,
        power: PowerState(onBattery: true, batteryPercent: 15, thermal: .nominal)
    )
    #expect(!floor.holdSystem)
    #expect(floor.reason == "battery 15%")
    #expect(floor.wantedBy.manualSessions == 1)
}

@Test func storedManualSessionIsLiveOnlyOnItsBootAndBeforeItsDeadline() {
    let timed = ManualSessionRecord(startedAt: now, deadline: now.addingTimeInterval(3_600),
                                    bootSessionID: "boot-a")
    #expect(timed.isLive(at: now.addingTimeInterval(3_599), bootSessionID: "boot-a"))
    #expect(!timed.isLive(at: now.addingTimeInterval(3_600), bootSessionID: "boot-a"))
    #expect(!timed.isLive(at: now, bootSessionID: "boot-b"))
    #expect(timed.demand == .manualSession(deadline: now.addingTimeInterval(3_600)))

    let indefinite = ManualSessionRecord(startedAt: now, deadline: nil, bootSessionID: "boot-a")
    #expect(indefinite.isLive(at: now.addingTimeInterval(90 * 86_400), bootSessionID: "boot-a"))
    #expect(!indefinite.isLive(at: now, bootSessionID: "boot-b"))
}

@Test func manualSessionStorageRoundTripsAndClears() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-manual-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = ManualSessionStorage(directory: directory)
    #expect(storage.load() == nil)

    let record = ManualSessionRecord(startedAt: now, deadline: now.addingTimeInterval(1_800.5),
                                     bootSessionID: "boot-a")
    try storage.save(record)
    #expect(storage.load() == record)

    try storage.save(nil)
    #expect(storage.load() == nil)
    try storage.save(nil)

    try Data("{not json".utf8).write(to: storage.url)
    #expect(storage.load() == nil)
}

@Test func bootSessionIdentityIsStableWithinThisBoot() {
    let id = BootSession.currentID()
    #expect(id != nil)
    #expect(id?.isEmpty == false)
    #expect(BootSession.currentID() == id)
}
