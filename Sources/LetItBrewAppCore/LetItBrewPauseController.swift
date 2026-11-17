import Foundation
import LetItBrewCore

/// Persists the user's explicit choice to let the Mac sleep. The pause is
/// intentionally durable: Let It Brew must not silently resume after a relaunch.
public protocol LetItBrewPausePersisting: Sendable {
    func loadPause() -> Bool
    func savePause(_ isPaused: Bool)
}

/// Persists the running manual session so it survives a relaunch or update.
public protocol ManualSessionPersisting: Sendable {
    func loadManualSession() -> ManualSessionRecord?
    /// Nil removes the stored session.
    func saveManualSession(_ record: ManualSessionRecord?)
}

/// For callers with no manual sessions to keep.
public struct NoManualSessionPersistence: ManualSessionPersisting {
    public init() {}
    public func loadManualSession() -> ManualSessionRecord? { nil }
    public func saveManualSession(_ record: ManualSessionRecord?) {}
}

/// How long a manual session lasts.
public enum ManualSessionLength: Equatable, Sendable {
    case duration(TimeInterval)
    /// Until this moment; see `ManualSessionUntil`.
    case until(Date)
    /// Until it is ended.
    case indefinitely

    /// The one-click durations in the menu.
    public static let presets: [(label: String, length: ManualSessionLength)] = [
        ("30m", .duration(30 * 60)),
        ("1h", .duration(3_600)),
        ("2h", .duration(2 * 3_600)),
        ("4h", .duration(4 * 3_600)),
    ]
}

/// "Until…": a time of day, meaning its next occurrence, today or tomorrow.
public enum ManualSessionUntil {
    /// The next moment after `now` at the hour and minute of `time`.
    public static func deadline(for time: Date, now: Date, calendar: Calendar = .current) -> Date {
        let parts = calendar.dateComponents([.hour, .minute], from: time)
        return calendar.nextDate(
            after: now,
            matching: DateComponents(hour: parts.hour, minute: parts.minute, second: 0),
            matchingPolicy: .nextTime
        ) ?? now
    }

    /// The word after the time field: "today", "tonight" from 6 PM, or
    /// "tomorrow".
    public static func dayWord(for deadline: Date, now: Date, calendar: Calendar = .current) -> String {
        guard calendar.isDate(deadline, inSameDayAs: now) else { return "tomorrow" }
        return calendar.component(.hour, from: deadline) < 18 ? "today" : "tonight"
    }

    /// The time the field opens at: two hours from now, on the next half hour.
    public static func defaultTime(now: Date) -> Date {
        let halfHour: TimeInterval = 30 * 60
        let later = now.addingTimeInterval(2 * 3_600)
        return Date(timeIntervalSinceReferenceDate:
            (later.timeIntervalSinceReferenceDate / halfHour).rounded(.up) * halfHour)
    }
}

/// The sleep holds Let It Brew may request after automatic policy and the
/// user's pause choice have both been applied.
public struct LetItBrewHoldIntent: Equatable, Sendable {
    public let system: Bool
    public let lidClosed: Bool
    public let display: Bool

    public init(system: Bool, lidClosed: Bool, display: Bool = false) {
        self.system = system
        self.lidClosed = lidClosed
        self.display = display
    }
}

/// Applies a persisted manual pause without affecting session observation.
/// Callers continue collecting and presenting sessions while this controller
/// suppresses only Let It Brew's three sleep holds.
///
/// It also owns the manual session. Pause and a manual session are last action
/// wins: starting a session clears Pause, and pausing ends the session.
public struct LetItBrewPauseController: Sendable {
    private let persistence: any LetItBrewPausePersisting
    private let manualSessions: any ManualSessionPersisting
    private let bootSessionID: String?
    public private(set) var isPaused: Bool
    public private(set) var manualSession: ManualSessionRecord?

    /// A stored session resumes only on the boot it started in and before its
    /// deadline; otherwise it is discarded. A stored pause wins over a stored
    /// session.
    public init(
        persistence: any LetItBrewPausePersisting,
        manualSessions: any ManualSessionPersisting = NoManualSessionPersistence(),
        bootSessionID: String? = nil,
        now: Date = Date()
    ) {
        self.persistence = persistence
        self.manualSessions = manualSessions
        self.bootSessionID = bootSessionID
        isPaused = persistence.loadPause()
        if let stored = manualSessions.loadManualSession() {
            if !isPaused, let bootSessionID,
               stored.isLive(at: now, bootSessionID: bootSessionID) {
                manualSession = stored
            } else {
                manualSessions.saveManualSession(nil)
            }
        }
    }

    public mutating func pause() {
        isPaused = true
        persistence.savePause(true)
        endManualSession()
    }

    public mutating func resume() {
        isPaused = false
        persistence.savePause(false)
    }

    /// Starts a session, replacing any running one, and clears Pause. An
    /// `until` time that is not in the future starts nothing.
    public mutating func startManualSession(_ length: ManualSessionLength, now: Date) {
        let deadline: Date?
        switch length {
        case .duration(let interval): deadline = now.addingTimeInterval(interval)
        case .until(let date): deadline = date
        case .indefinitely: deadline = nil
        }
        if let deadline, deadline <= now { return }
        if isPaused { resume() }
        setManualSession(ManualSessionRecord(
            startedAt: now, deadline: deadline, bootSessionID: bootSessionID ?? ""
        ))
    }

    /// Adds an hour to a running timed session's deadline.
    public mutating func extendManualSession(now: Date) {
        guard var session = manualSession, let deadline = session.deadline,
              !session.isExpired(at: now)
        else { return }
        session.deadline = deadline.addingTimeInterval(3_600)
        setManualSession(session)
    }

    public mutating func endManualSession() {
        guard manualSession != nil else { return }
        setManualSession(nil)
    }

    /// Ends a session whose deadline has come.
    public mutating func expireManualSession(at now: Date) {
        guard manualSession?.isExpired(at: now) == true else { return }
        setManualSession(nil)
    }

    /// The running session as a `decide()` input, if it still holds at `now`.
    public func manualSessionDemand(at now: Date) -> KeepAwakeDemand? {
        guard let manualSession, !manualSession.isExpired(at: now) else { return nil }
        return manualSession.demand
    }

    private mutating func setManualSession(_ session: ManualSessionRecord?) {
        manualSession = session
        manualSessions.saveManualSession(session)
    }

    public func resolve(
        systemHold: Bool,
        lidClosedHold: Bool,
        displayHold: Bool = false
    ) -> LetItBrewHoldIntent {
        guard !isPaused else {
            return LetItBrewHoldIntent(
                system: false,
                lidClosed: false,
                display: false
            )
        }
        return LetItBrewHoldIntent(
            system: systemHold,
            lidClosed: lidClosedHold,
            display: displayHold
        )
    }
}
