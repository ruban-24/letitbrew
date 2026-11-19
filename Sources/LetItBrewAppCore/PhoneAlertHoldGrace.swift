import Foundation

/// Keeps a hold that a poll releases while that poll's phone alerts are on
/// their way. The finished and stopped alerts come in the same poll that
/// releases, and with the lid closed the release starts sleep, which would
/// lose the send or deliver it stale on wake. Never longer than `limit`:
/// battery, heat and Low Power Mode releases are safety releases.
public struct PhoneAlertHoldGrace: Sendable {
    public static let limit: TimeInterval = 15

    public struct Hold: Equatable, Sendable {
        public var system: Bool
        public var lidClosed: Bool

        public init(system: Bool, lidClosed: Bool) {
            self.system = system
            self.lidClosed = lidClosed
        }

        func union(_ other: Hold) -> Hold {
            Hold(system: system || other.system, lidClosed: lidClosed || other.lidClosed)
        }
    }

    private var kept: Hold?
    private var deadline = Date.distantPast
    private var unsettled = 0
    /// Names the current grace, so a send from an earlier one settling never
    /// ends it. Read after `hold` to tag the sends that poll started.
    public private(set) var generation = 0

    public init() {}

    /// A released hold is being kept for phone sends.
    public var isKeeping: Bool { kept != nil }

    /// The hold to apply this poll. `applied` is the hold in place before it;
    /// `sendingToPhone` says this poll is sending phone alerts.
    public mutating func hold(
        wanted: Hold,
        applied: Hold,
        sendingToPhone: Bool,
        now: Date
    ) -> Hold {
        if let kept {
            if unsettled > 0, now < deadline {
                if sendingToPhone { unsettled += 1 }
                return kept.union(wanted)
            }
            self.kept = nil
            return wanted
        }
        let releases = (applied.system && !wanted.system)
            || (applied.lidClosed && !wanted.lidClosed)
        guard releases, sendingToPhone else { return wanted }
        kept = applied
        deadline = now.addingTimeInterval(Self.limit)
        unsettled = 1
        generation += 1
        return applied.union(wanted)
    }

    /// One poll's phone sends finished, sent or dropped. True when that was
    /// the last one, so the release can be applied now.
    @discardableResult
    public mutating func sendSettled(generation: Int) -> Bool {
        guard kept != nil, generation == self.generation, unsettled > 0 else { return false }
        unsettled -= 1
        return unsettled == 0
    }

    /// Drops the grace, for releases the person asked for.
    public mutating func end() {
        kept = nil
        unsettled = 0
    }
}
