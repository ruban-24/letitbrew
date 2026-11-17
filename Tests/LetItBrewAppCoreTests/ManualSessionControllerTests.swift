import Foundation
import Testing
import LetItBrewCore
@testable import LetItBrewAppCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)
private let hour: TimeInterval = 3_600

private final class Store: LetItBrewPausePersisting, ManualSessionPersisting, @unchecked Sendable {
    var paused: Bool
    var session: ManualSessionRecord?

    init(paused: Bool = false, session: ManualSessionRecord? = nil) {
        self.paused = paused
        self.session = session
    }

    func loadPause() -> Bool { paused }
    func savePause(_ isPaused: Bool) { paused = isPaused }
    func loadManualSession() -> ManualSessionRecord? { session }
    func saveManualSession(_ record: ManualSessionRecord?) { session = record }
}

private func controller(
    _ store: Store, boot: String? = "boot-a", at time: Date = now
) -> LetItBrewPauseController {
    LetItBrewPauseController(persistence: store, manualSessions: store,
                             bootSessionID: boot, now: time)
}

@Test func timedSessionHoldsUntilItsDeadlineThenEnds() {
    let store = Store()
    var keepAwake = controller(store)
    #expect(keepAwake.manualSessionDemand(at: now) == nil)

    keepAwake.startManualSession(.duration(2 * hour), now: now)

    #expect(keepAwake.manualSession?.deadline == now.addingTimeInterval(2 * hour))
    #expect(keepAwake.manualSessionDemand(at: now)
            == .manualSession(deadline: now.addingTimeInterval(2 * hour)))
    #expect(store.session?.bootSessionID == "boot-a")

    keepAwake.expireManualSession(at: now.addingTimeInterval(2 * hour - 1))
    #expect(keepAwake.manualSession != nil)

    keepAwake.expireManualSession(at: now.addingTimeInterval(2 * hour))
    #expect(keepAwake.manualSession == nil)
    #expect(keepAwake.manualSessionDemand(at: now.addingTimeInterval(2 * hour)) == nil)
    #expect(store.session == nil)
}

@Test func indefiniteSessionHoldsUntilEnded() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.indefinitely, now: now)

    let muchLater = now.addingTimeInterval(400 * hour)
    keepAwake.expireManualSession(at: muchLater)
    #expect(keepAwake.manualSessionDemand(at: muchLater) == .manualSession(deadline: nil))

    keepAwake.endManualSession()
    #expect(keepAwake.manualSession == nil)
    #expect(keepAwake.manualSessionDemand(at: muchLater) == nil)
    #expect(store.session == nil)
}

@Test func untilStartsASessionEndingAtThatTime() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.until(now.addingTimeInterval(5 * hour)), now: now)
    #expect(keepAwake.manualSession?.deadline == now.addingTimeInterval(5 * hour))

    // A time that has already passed starts nothing.
    var other = controller(Store())
    other.startManualSession(.until(now), now: now)
    #expect(other.manualSession == nil)
}

@Test func extendAddsAnHourToTheDeadline() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.duration(30 * 60), now: now)

    keepAwake.extendManualSession(now: now.addingTimeInterval(10 * 60))
    #expect(keepAwake.manualSession?.deadline == now.addingTimeInterval(90 * 60))
    #expect(store.session?.deadline == now.addingTimeInterval(90 * 60))

    keepAwake.extendManualSession(now: now.addingTimeInterval(20 * 60))
    #expect(keepAwake.manualSession?.deadline == now.addingTimeInterval(150 * 60))
}

@Test func extendDoesNothingToAnIndefiniteOrEndedSession() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.extendManualSession(now: now)
    #expect(keepAwake.manualSession == nil)

    keepAwake.startManualSession(.indefinitely, now: now)
    keepAwake.extendManualSession(now: now)
    #expect(keepAwake.manualSession?.deadline == nil)

    keepAwake.startManualSession(.duration(hour), now: now)
    keepAwake.extendManualSession(now: now.addingTimeInterval(hour))
    #expect(keepAwake.manualSessionDemand(at: now.addingTimeInterval(hour)) == nil)
}

@Test func startingASessionReplacesTheRunningOne() {
    var keepAwake = controller(Store())
    keepAwake.startManualSession(.indefinitely, now: now)
    keepAwake.startManualSession(.duration(hour), now: now.addingTimeInterval(60))
    #expect(keepAwake.manualSession?.deadline == now.addingTimeInterval(60 + hour))
}

@Test func startingASessionClearsPause() {
    let store = Store(paused: true)
    var keepAwake = controller(store)
    #expect(keepAwake.isPaused)

    keepAwake.startManualSession(.duration(hour), now: now)

    #expect(!keepAwake.isPaused)
    #expect(!store.paused)
    #expect(keepAwake.resolve(systemHold: true, lidClosedHold: true)
            == LetItBrewHoldIntent(system: true, lidClosed: true))
}

@Test func pausingEndsTheSession() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.indefinitely, now: now)

    keepAwake.pause()

    #expect(keepAwake.isPaused)
    #expect(keepAwake.manualSession == nil)
    #expect(keepAwake.manualSessionDemand(at: now) == nil)
    #expect(store.session == nil)

    // Resuming does not bring the session back.
    keepAwake.resume()
    #expect(keepAwake.manualSession == nil)
}

@Test func sessionResumesAfterRelaunchOnTheSameBootWithItsOriginalDeadline() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.duration(4 * hour), now: now)

    let relaunched = controller(store, at: now.addingTimeInterval(hour))
    #expect(relaunched.manualSession?.deadline == now.addingTimeInterval(4 * hour))
    #expect(relaunched.manualSessionDemand(at: now.addingTimeInterval(hour))
            == .manualSession(deadline: now.addingTimeInterval(4 * hour)))
    #expect(store.session != nil)
}

@Test func storedSessionIsDiscardedAfterReboot() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.indefinitely, now: now)

    let afterReboot = controller(store, boot: "boot-b", at: now.addingTimeInterval(60))
    #expect(afterReboot.manualSession == nil)
    #expect(store.session == nil)
}

@Test func storedSessionIsDiscardedWhenTheBootCannotBeRead() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.indefinitely, now: now)

    let unknownBoot = controller(store, boot: nil, at: now.addingTimeInterval(60))
    #expect(unknownBoot.manualSession == nil)
    #expect(store.session == nil)
}

@Test func storedSessionIsDiscardedOnceExpired() {
    let store = Store()
    var keepAwake = controller(store)
    keepAwake.startManualSession(.duration(30 * 60), now: now)

    let relaunched = controller(store, at: now.addingTimeInterval(30 * 60))
    #expect(relaunched.manualSession == nil)
    #expect(store.session == nil)
}

@Test func storedPauseWinsOverAStoredSession() {
    let store = Store(
        paused: true,
        session: ManualSessionRecord(startedAt: now, deadline: nil, bootSessionID: "boot-a")
    )
    let relaunched = controller(store)
    #expect(relaunched.isPaused)
    #expect(relaunched.manualSession == nil)
    #expect(store.session == nil)
}

@Test func untilTimeResolvesToItsNextOccurrence() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
    func at(_ day: Int, _ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day,
                                           hour: hour, minute: minute))!
    }
    let afternoon = at(17, 14, 5)

    let tonight = ManualSessionUntil.deadline(for: at(1, 23, 30), now: afternoon, calendar: calendar)
    #expect(tonight == at(17, 23, 30))
    #expect(ManualSessionUntil.dayWord(for: tonight, now: afternoon, calendar: calendar) == "tonight")

    let laterToday = ManualSessionUntil.deadline(for: at(1, 17, 59), now: afternoon, calendar: calendar)
    #expect(laterToday == at(17, 17, 59))
    #expect(ManualSessionUntil.dayWord(for: laterToday, now: afternoon, calendar: calendar) == "today")

    let evening = ManualSessionUntil.deadline(for: at(1, 18, 0), now: afternoon, calendar: calendar)
    #expect(ManualSessionUntil.dayWord(for: evening, now: afternoon, calendar: calendar) == "tonight")

    let tomorrow = ManualSessionUntil.deadline(for: at(1, 7, 0), now: afternoon, calendar: calendar)
    #expect(tomorrow == at(18, 7, 0))
    #expect(ManualSessionUntil.dayWord(for: tomorrow, now: afternoon, calendar: calendar) == "tomorrow")

    // The current minute has already started, so it means tomorrow.
    let sameMinute = ManualSessionUntil.deadline(for: at(1, 14, 5), now: afternoon, calendar: calendar)
    #expect(sameMinute == at(18, 14, 5))
}

@Test func presetsAreTheApprovedDurations() {
    #expect(ManualSessionLength.presets.map(\.label) == ["30m", "1h", "2h", "4h"])
    #expect(ManualSessionLength.presets.map(\.length) == [
        .duration(30 * 60), .duration(hour), .duration(2 * hour), .duration(4 * hour),
    ])
}

@Test func untilFieldOpensTwoHoursAheadOnTheNextHalfHour() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Australia/Sydney")!
    func at(_ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 17,
                                           hour: hour, minute: minute, second: second))!
    }
    #expect(ManualSessionUntil.defaultTime(now: at(21, 5)) == at(23, 30))
    #expect(ManualSessionUntil.defaultTime(now: at(21, 30)) == at(23, 30))
    #expect(ManualSessionUntil.defaultTime(now: at(21, 30, 1)) == at(0, 0).addingTimeInterval(86_400))
}
