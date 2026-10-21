import Foundation
import LetItBrewCore

/// Credits key presses and clicks to the app that was frontmost when they
/// happened, so typing in another app, such as a chat, cannot answer a
/// session's approval prompt.
///
/// The HID counters report only each kind's latest event, so the caller reads
/// them on every poll and again as every activation change arrives, and
/// credits each time once `OwnMenuInputFilter` can judge it.
public struct FrontmostInputAttribution: Equatable, Sendable {
    /// A click that brings an app forward lands just before the app reports
    /// it is active, and it may press the button it lands on.
    public static let activationLead: TimeInterval = 1
    /// `WaitAnswerLatch` keeps an answer from the first poll that sees it,
    /// so older history is no longer needed.
    public static let retention: TimeInterval = 3_600

    private struct Activation: Equatable, Sendable {
        let app: Int32?
        let at: Date
    }

    private var activations: [Activation] = []
    private var lastInputByApp: [Int32: Date] = [:]
    /// Input from before the first recorded activation, such as an approval
    /// made before Let It Brew relaunched. Its app is unknown, so it counts
    /// for every app.
    private var unattributedInput: Date = .distantPast

    public init() {}

    /// Follows the app that just came to the front. Activations stay in time
    /// order even when a caller's clock reading lags an earlier one.
    public mutating func activate(_ app: Int32?, at date: Date) {
        guard activations.last?.app != app else { return }
        let date = max(date, activations.last?.at ?? date)
        activations.append(Activation(app: app, at: date))
        // Keeps the activation still in effect at the cutoff.
        let cutoff = date.addingTimeInterval(-Self.retention)
        if let inEffect = activations.lastIndex(where: { $0.at <= cutoff }), inEffect > 0 {
            activations.removeFirst(inEffect)
        }
    }

    /// Credits input to the app in front when it happened, and to an app that
    /// came forward just after, because the input may be the click that
    /// brought it forward.
    public mutating func credit(inputAt date: Date) {
        var apps: [Int32] = []
        if let inEffect = activations.last(where: { $0.at <= date }) {
            if let app = inEffect.app { apps.append(app) }
        } else {
            unattributedInput = max(unattributedInput, date)
        }
        let lead = date.addingTimeInterval(Self.activationLead)
        for activation in activations where activation.at > date && activation.at <= lead {
            if let app = activation.app { apps.append(app) }
        }
        for app in apps {
            lastInputByApp[app] = max(lastInputByApp[app] ?? .distantPast, date)
        }
        guard let newest = lastInputByApp.values.max() else { return }
        let cutoff = newest.addingTimeInterval(-Self.retention)
        lastInputByApp = lastInputByApp.filter { $0.value >= cutoff }
    }

    /// The input that could have answered a prompt shown in `app`. An
    /// unreadable counter stays unreadable, because evidence may be missing.
    public func observation(
        forApp app: Int32,
        global: UserInputObservation
    ) -> UserInputObservation {
        guard case .lastInput = global else { return .unavailable }
        return .lastInput(at: max(lastInputByApp[app] ?? .distantPast, unattributedInput))
    }
}
