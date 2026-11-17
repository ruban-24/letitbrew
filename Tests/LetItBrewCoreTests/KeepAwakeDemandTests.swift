import Foundation
import Testing
@testable import LetItBrewCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let plugged = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal)

private func hold(pid: Int32 = 4_182, label: String = "npm run build") -> HoldRecord {
    HoldRecord(pid: pid, label: label, startedAt: now.addingTimeInterval(-60))
}

private func working(updatedAgo seconds: TimeInterval = 0) -> SessionRecord {
    SessionRecord(id: UUID().uuidString, tool: "claude", state: .working, detail: nil,
                  cwd: "/tmp/repo", pid: 1, updatedAt: now.addingTimeInterval(-seconds))
}

@Test func liveHoldKeepsTheMacAwakeWithNoAgents() {
    var settings = Settings()
    settings.allowDisplaysToSleep = false
    let decision = decide(sessions: [], demands: [.hold(hold())], now: now,
                          settings: settings, power: plugged)
    #expect(decision.holdSystem)
    #expect(decision.holdLidClosed)
    #expect(decision.holdDisplay)
    #expect(decision.reason == "1 hold")
    #expect(decision.wantedBy == HoldDemandCount(agents: 0, holds: 1))
}

@Test func holdFollowsTheClosedLidSettingLikeAgents() {
    var settings = Settings()
    settings.lidClosedFollowsSession = false
    let decision = decide(sessions: [], demands: [.hold(hold())], now: now,
                          settings: settings, power: plugged)
    #expect(decision.holdSystem)
    #expect(!decision.holdLidClosed)
}

@Test func holdsCombineWithWorkingAgents() {
    let decision = decide(
        sessions: [working(), working()],
        demands: [.hold(hold(pid: 1)), .hold(hold(pid: 2)), .hold(hold(pid: 3))],
        now: now, settings: Settings(), power: plugged
    )
    #expect(decision.holdSystem)
    #expect(decision.reason == "2 working, 3 holds")
    #expect(decision.wantedBy == HoldDemandCount(agents: 2, holds: 3))
}

@Test func agentGoingIdleLeavesTheHoldInPlace() {
    let idle = SessionRecord(id: "a", tool: "claude", state: .idle, detail: nil, cwd: "/tmp/repo",
                             pid: 1, updatedAt: now)
    let decision = decide(sessions: [idle], demands: [.hold(hold())], now: now,
                          settings: Settings(), power: plugged)
    #expect(decision.holdSystem)
    #expect(decision.reason == "1 hold")
}

@Test func holdsAreNeverBoundByTheMonitoringLimit() {
    var settings = Settings()
    settings.monitoringHoldLimit = 60
    let old = HoldRecord(pid: 9, label: "render", startedAt: now.addingTimeInterval(-86_400))
    let decision = decide(sessions: [], demands: [.hold(old)], now: now,
                          settings: settings, power: plugged)
    #expect(decision.holdSystem)
}

/// Each power rule releases a hold, in the same priority order as agents,
/// and still reports that a hold wanted the Mac awake.
@Test func powerRulesReleaseHoldsInPriorityOrder() {
    var settings = Settings()
    settings.onlyWhileConnectedToPower = true
    settings.respectLowPowerMode = true
    settings.batteryFloor = 20
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
        let decision = decide(sessions: [], demands: [.hold(hold())], now: now,
                              settings: settings, power: power)
        #expect(!decision.holdSystem)
        #expect(!decision.holdLidClosed)
        #expect(decision.reason == reason)
        #expect(decision.wantedBy == HoldDemandCount(agents: 0, holds: 1))
    }

    settings.onlyWhileConnectedToPower = false
    let floor = decide(
        sessions: [], demands: [.hold(hold())], now: now, settings: settings,
        power: PowerState(onBattery: true, batteryPercent: 15, thermal: .critical,
                          lowPowerModeEnabled: true)
    )
    #expect(!floor.holdSystem)
    #expect(floor.reason == "battery 15%")
    #expect(floor.wantedBy.holds == 1)
}

@Test func releaseWithNothingWantedReportsNoDemand() {
    let decision = decide(sessions: [], now: now, settings: Settings(),
                          power: PowerState(onBattery: false, batteryPercent: 100,
                                            thermal: .critical))
    #expect(!decision.holdSystem)
    #expect(decision.wantedBy.isEmpty)
}

@Test func deadHoldProcessesAreIgnored() {
    let records = [hold(pid: 10, label: "alive"), hold(pid: 11, label: "dead")]
    let live = HoldRecord.live(records, isAlive: { $0 == 10 })
    #expect(live.map(\.label) == ["alive"])

    let decision = decide(sessions: [], demands: HoldRecord.live(records, isAlive: { _ in false })
        .map(KeepAwakeDemand.hold), now: now, settings: Settings(), power: plugged)
    #expect(!decision.holdSystem)
    #expect(decision.reason == "no agent sessions")
}

@Test func holdStoragePrunesDeadRecordsAndKeepsLiveOnes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("letitbrew-holds-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let storage = HoldStorage(directory: directory)
    try storage.write(hold(pid: 10, label: "alive"))
    try storage.write(hold(pid: 11, label: "dead"))
    try Data("{not json".utf8).write(to: directory.appendingPathComponent("12.json"))

    let live = storage.loadLive(isAlive: { $0 == 10 })

    #expect(live.map(\.pid) == [10])
    let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    // The unreadable file may be mid-write, so it is skipped, not deleted.
    #expect(remaining == ["10.json", "12.json"])
    storage.remove(pid: 10)
    #expect(storage.loadAll().isEmpty)
}

@Test func holdLabelIsOneShortLine() {
    #expect(HoldRecord.label(for: ["npm", "run", "build"]) == "npm run build")
    #expect(HoldRecord.label(for: ["echo", "a\nb\tc\u{1B}[31m"]) == "echo a b c [31m")
    let long = HoldRecord.label(for: [String(repeating: "x", count: 200)])
    #expect(long.count == HoldRecord.maxLabelLength)
    #expect(long.hasSuffix("…"))
}

@Test func holdWarnsOnlyWhenTheAppCannotHold() {
    #expect(HoldWarning.message(appRunning: true, paused: false) == nil)
    #expect(HoldWarning.message(appRunning: true, paused: true)?.contains("paused") == true)
    #expect(HoldWarning.message(appRunning: false, paused: false)?.contains("isn't running") == true)
    #expect(HoldWarning.message(appRunning: false, paused: true)?.contains("isn't running") == true)
}
