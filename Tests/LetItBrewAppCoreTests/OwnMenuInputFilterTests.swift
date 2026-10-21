import Foundation
import Testing
@testable import LetItBrewAppCore
import LetItBrewCore

private let t0 = Date(timeIntervalSince1970: 5_000)

private func reading(key: TimeInterval, click: TimeInterval) -> UserAnswerInputReading {
    UserAnswerInputReading(
        lastKeyPress: t0.addingTimeInterval(key),
        lastClick: t0.addingTimeInterval(click)
    )
}

@Test func withoutTheMenuEveryKeyPressAndClickCounts() {
    let filter = OwnMenuInputFilter()
    #expect(filter.observation(reading(key: 3, click: 8), now: t0.addingTimeInterval(30))
        == .lastInput(at: t0.addingTimeInterval(8)))
    #expect(filter.observation(nil, now: t0) == .unavailable)
}

@Test func theOpeningClickAndInputInsideTheMenuAreDiscarded() {
    var filter = OwnMenuInputFilter()
    filter.menuOpened(at: t0.addingTimeInterval(10))
    // The status-item click lands just before the menu reports it is open.
    #expect(filter.observation(reading(key: 2, click: 9.6), now: t0.addingTimeInterval(12))
        == .lastInput(at: t0.addingTimeInterval(2)))
    #expect(filter.observation(reading(key: 15, click: 20), now: t0.addingTimeInterval(21)) == .lastInput(at: .distantPast))
}

@Test func inputAfterTheMenuClosesCountsAgain() {
    var filter = OwnMenuInputFilter()
    filter.menuOpened(at: t0.addingTimeInterval(10))
    filter.menuClosed(at: t0.addingTimeInterval(20))
    #expect(filter.observation(reading(key: 21, click: 20.1), now: t0.addingTimeInterval(22))
        == .lastInput(at: t0.addingTimeInterval(21)))
    #expect(filter.observation(reading(key: 5, click: 19), now: t0.addingTimeInterval(22))
        == .lastInput(at: t0.addingTimeInterval(5)))
}

@Test func aCloseWithoutAnOpenIsIgnored() {
    var filter = OwnMenuInputFilter()
    filter.menuClosed(at: t0)
    #expect(filter == OwnMenuInputFilter())
}

@Test func freshInputWaitsUntilTheMenuCanReportItOpened() {
    var filter = OwnMenuInputFilter()
    // A poll lands between the status-item click and the menu's onAppear.
    let early = filter.observation(reading(key: 1, click: 10), now: t0.addingTimeInterval(10.2))
    #expect(early == .lastInput(at: t0.addingTimeInterval(1)))
    filter.menuOpened(at: t0.addingTimeInterval(10.3))
    let later = filter.observation(reading(key: 1, click: 10), now: t0.addingTimeInterval(11))
    #expect(later == .lastInput(at: t0.addingTimeInterval(1)))
}
