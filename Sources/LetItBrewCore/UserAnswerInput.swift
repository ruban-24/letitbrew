import CoreGraphics
import Foundation

/// When the person last pressed a key or clicked, from the HID system's own
/// per-event idle counters. Pointer movement and scrolling are deliberately
/// excluded: they cannot answer a prompt, and they happen incidentally.
/// Reading this needs no permission and reveals no keys, positions, or
/// applications.
public struct UserAnswerInputReading: Equatable, Sendable {
    public let lastKeyPress: Date
    public let lastClick: Date

    public init(lastKeyPress: Date, lastClick: Date) {
        self.lastKeyPress = lastKeyPress
        self.lastClick = lastClick
    }
}

public struct CGUserAnswerInput: Sendable {
    public init() {}

    /// Nil when a counter is unreadable.
    public func current(now: Date) -> UserAnswerInputReading? {
        Self.reading(now: now) { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
    }

    /// Pure assembly over a counter source, separated so tests need no HID.
    static func reading(
        now: Date,
        secondsSince: (CGEventType) -> Double
    ) -> UserAnswerInputReading? {
        func last(_ types: [CGEventType]) -> Date? {
            var newest = Date.distantPast
            for type in types {
                let seconds = secondsSince(type)
                guard seconds.isFinite, seconds >= 0 else { return nil }
                newest = max(newest, now.addingTimeInterval(-seconds))
            }
            return newest
        }
        guard let key = last([.keyDown]),
              let click = last([.leftMouseDown, .rightMouseDown, .otherMouseDown])
        else { return nil }
        return UserAnswerInputReading(lastKeyPress: key, lastClick: click)
    }
}

/// The most recent input that could have answered a waiting prompt. Only a
/// Waiting session consults it.
public enum UserInputObservation: Equatable, Sendable {
    case lastInput(at: Date)
    /// The reading failed. A wait then keeps its hold, because the person may
    /// have answered and no hook would say so.
    case unavailable

    /// For callers that observe no input: every wait releases.
    public static let none = UserInputObservation.lastInput(at: .distantPast)

    public init(_ reading: UserAnswerInputReading?) {
        guard let reading else {
            self = .unavailable
            return
        }
        self = .lastInput(at: max(reading.lastKeyPress, reading.lastClick))
    }
}
