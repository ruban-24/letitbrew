import CoreGraphics
import Foundation
import Testing
@testable import LetItBrewCore

private let now = Date(timeIntervalSince1970: 1_700_000_000)

@Test func keyPressesAndClicksAreReadSeparatelyWithoutPointerMotion() {
    var asked: [CGEventType] = []
    let reading = CGUserAnswerInput.reading(now: now) { type in
        asked.append(type)
        switch type {
        case .keyDown: return 4
        case .leftMouseDown: return 30
        case .rightMouseDown: return 9
        default: return 600
        }
    }
    #expect(reading == UserAnswerInputReading(
        lastKeyPress: now.addingTimeInterval(-4),
        lastClick: now.addingTimeInterval(-9)
    ))
    #expect(!asked.contains(.mouseMoved))
    #expect(!asked.contains(.scrollWheel))
    #expect(UserInputObservation(reading) == .lastInput(at: now.addingTimeInterval(-4)))
}

@Test func anUnreadableCounterMakesTheWholeReadingUnavailable() {
    for bad in [-1, Double.nan, .infinity] {
        let reading = CGUserAnswerInput.reading(now: now) { $0 == .rightMouseDown ? bad : 5 }
        #expect(reading == nil)
        #expect(UserInputObservation(reading) == .unavailable)
    }
}

@Test func theLiveCountersAreReadable() {
    let reading = CGUserAnswerInput().current(now: now)
    #expect(reading != nil)
    if let reading {
        #expect(reading.lastKeyPress <= now)
        #expect(reading.lastClick <= now)
    }
}
