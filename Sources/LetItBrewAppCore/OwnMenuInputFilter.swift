import Foundation
import LetItBrewCore

/// Discards key presses and clicks aimed at Let It Brew's own menu, so opening
/// the menu to see that an agent is waiting does not count as answering it.
///
/// The HID counters report only each kind's latest event, so a discarded one
/// can hide an earlier answer; `WaitAnswerLatch` keeps evidence it already saw
/// on an earlier poll.
public struct OwnMenuInputFilter: Equatable, Sendable {
    /// The status-item click lands at most this long before the menu reports
    /// it is open. Only that click is discarded, so an Enter or click that
    /// answered just before it still counts.
    public static let openingLead: TimeInterval = 1
    /// Times read from the counters jitter slightly between readings.
    public static let sameEventTolerance: TimeInterval = 0.05
    /// A menu that never reported closing stops discarding input after this
    /// long, so a missed close cannot hide answers indefinitely.
    public static let maximumOpenDuration: TimeInterval = 300
    /// A click that closes the menu lands just before it reports closing.
    public static let closingLag: TimeInterval = 0.25
    /// Input this recent waits for the next poll, so the menu can report it
    /// opened before the click that opened it is judged.
    public static let settlingDelay: TimeInterval = 0.5

    private var openedAt: Date?
    private var closedAt: Date?
    private var openingClick: Date?

    public init() {}

    /// `lastClick` is the click counter as the menu opens: the status-item
    /// click, unless the menu was opened another way.
    public mutating func menuOpened(at date: Date, lastClick: Date?) {
        openedAt = date
        closedAt = nil
        openingClick = lastClick.flatMap {
            date.timeIntervalSince($0) <= Self.openingLead ? $0 : nil
        }
    }

    public mutating func menuClosed(at date: Date) {
        guard openedAt != nil else { return }
        closedAt = date
    }

    public func observation(
        _ reading: UserAnswerInputReading?,
        now: Date
    ) -> UserInputObservation {
        guard let reading else { return .unavailable }
        let kept = [reading.lastKeyPress, reading.lastClick].filter {
            counts($0, now: now) == true
        }
        return .lastInput(at: kept.max() ?? .distantPast)
    }

    /// Whether input at `date` may answer a wait, or nil while it is too
    /// recent to judge.
    public func counts(_ date: Date, now: Date) -> Bool? {
        guard date <= now.addingTimeInterval(-Self.settlingDelay) else { return nil }
        return !isOwnMenuInput(date)
    }

    private func isOwnMenuInput(_ date: Date) -> Bool {
        if let openingClick, abs(date.timeIntervalSince(openingClick)) <= Self.sameEventTolerance {
            return true
        }
        guard let openedAt, date >= openedAt else { return false }
        let end = closedAt?.addingTimeInterval(Self.closingLag)
            ?? openedAt.addingTimeInterval(Self.maximumOpenDuration)
        return date <= end
    }
}
