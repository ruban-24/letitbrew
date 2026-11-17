import Foundation
import LetItBrewCore

/// The menu's Keep awake row while a manual session runs:
/// "Awake · 1:42 left", "Until 3:56 PM", with +1h and End.
public struct MenuKeepAwakeRunningPresentation: Equatable, Sendable {
    /// "Awake", or "Held back" while a power rule releases the hold.
    public let status: String
    /// "H:MM", or nil for a session with no time limit.
    public let timeLeft: String?
    public let detail: String
    /// Whether +1h is offered: timed sessions only.
    public let canExtend: Bool

    public var title: String {
        timeLeft.map { "\(status) · \($0) left" } ?? "\(status) · No time limit"
    }
}

public enum MenuKeepAwakePresentationPolicy {
    /// Under the duration buttons while Let It Brew is paused.
    public static let pausedCaption = "Starting one turns Let It Brew back on."

    public static func running(
        _ session: ManualSessionRecord,
        now: Date,
        isHeldBack: Bool,
        formatTime: (Date) -> String
    ) -> MenuKeepAwakeRunningPresentation {
        MenuKeepAwakeRunningPresentation(
            status: isHeldBack ? "Held back" : "Awake",
            timeLeft: session.timeLeft(at: now),
            detail: session.deadline.map { "Until \(formatTime($0))" } ?? "Until you end it",
            canExtend: session.deadline != nil
        )
    }

    /// The header's detail line while a session runs, or nil to use
    /// `MenuHeaderDetailCopy`. Agents and holds holding too follow the
    /// session line.
    public static func headerDetail(
        session: ManualSessionRecord?,
        isKeepingAwake: Bool,
        isHeldBack: Bool,
        rows: [MenuSessionPresentation],
        holdCount: Int,
        now: Date,
        formatTime: (Date) -> String
    ) -> String? {
        guard let session, session.deadline.map({ $0 > now }) ?? true else { return nil }
        if isHeldBack { return "Your keep-awake session is held back" }
        guard isKeepingAwake else { return nil }
        var parts = [session.deadline.map {
            "You asked to keep it awake until \(formatTime($0))"
        } ?? "You asked to keep it awake"]
        if rows.contains(where: \.isWorking) || holdCount > 0 {
            parts.append(MenuHeaderDetailCopy.resolve(context: .awake, rows: rows, holdCount: holdCount))
        } else if case let waiting = rows.count(where: \.isWaiting), waiting > 0 {
            parts.append("\(waiting) waiting")
        }
        return parts.joined(separator: " · ")
    }
}
