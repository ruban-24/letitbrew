import Foundation

public struct Settings: Equatable, Sendable {
    /// Release below this charge, on battery only.
    public var batteryFloor: Int = 20
    public var onlyWhileConnectedToPower = false
    public var respectLowPowerMode = false
    public var allowDisplaysToSleep = true
    /// Whether lid-closed mode follows the session automatically.
    public var lidClosedFollowsSession: Bool = true
    /// Backstop eviction age for session records.
    public var staleTTL: TimeInterval = 12 * 3_600
    /// A working session with no newer hook event is presented as silent
    /// after this interval. Presentation only: it still holds the Mac awake.
    public var workingSilenceThreshold: TimeInterval = 120
    /// How long a session family may stay silent while it holds only under
    /// `MonitoringLease`: a turn that ended with background work or scheduled
    /// crons, or a subagent's own record. Any hook in the family renews it. A
    /// forgotten shell or a killed subagent cannot be told from long work by
    /// its status alone, so the hold is bounded instead of released.
    public var monitoringHoldLimit: TimeInterval = 7_200

    public init() {}
}

public struct PowerState: Equatable, Sendable {
    public var onBattery: Bool
    public var batteryPercent: Int
    public var thermal: ProcessInfo.ThermalState
    public var lowPowerModeEnabled: Bool
    /// False means this reading itself could not be trusted — an IOKit call
    /// FAILED outright, not "this machine confirmed it has no battery".
    /// Defaults to true so every plugged-in/100% reading (a confirmed-empty
    /// desktop source list, and every existing call site/test) is
    /// unaffected; only a genuine API failure sets it false. See IMPORTANT 4:
    /// `decide()` must not bypass the battery floor on an unknown reading.
    public var trusted: Bool

    public init(
        onBattery: Bool,
        batteryPercent: Int,
        thermal: ProcessInfo.ThermalState,
        lowPowerModeEnabled: Bool = false,
        trusted: Bool = true
    ) {
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.thermal = thermal
        self.lowPowerModeEnabled = lowPowerModeEnabled
        self.trusted = trusted
    }
}

public struct Decision: Equatable, Sendable {
    public var holdSystem: Bool
    public var holdLidClosed: Bool
    public var holdDisplay: Bool
    /// Human-readable explanation, shown in the menu and the status output.
    public var reason: String

    public init(holdSystem: Bool, holdLidClosed: Bool, holdDisplay: Bool = false, reason: String) {
        self.holdSystem = holdSystem
        self.holdLidClosed = holdLidClosed
        self.holdDisplay = holdDisplay
        self.reason = reason
    }
}

/// Remembers which Waiting sessions local input may have answered.
///
/// A Waiting session is blocked on the person, so it releases the hold. But
/// approving a Claude or Copilot prompt fires no hook before the approved tool
/// runs, and a skipped question may not fire one either. A key press or click
/// after the wait began is therefore treated as a possible answer: the session
/// holds again, as Working, until its next hook. The worst case is the hold a
/// Claude approval kept before Waiting existed.
///
/// The latch keeps that evidence for the life of the wait, so a later input
/// the caller discards (such as a click in Let It Brew's own menu) cannot
/// erase an earlier answer.
public struct WaitAnswerLatch: Equatable, Sendable {
    /// Input this long before a Claude permission notification still counts:
    /// Claude sends it about six seconds after the prompt appears, so it can
    /// land just after the keystroke that answered.
    public static let answerLeadTolerance: TimeInterval = 3
    /// Copilot's notification timing is unverified, so a fast answer keeps a
    /// margin for hook delivery without counting the Enter that submitted a
    /// turn seconds earlier.
    public static let copilotAnswerLeadTolerance: TimeInterval = 1

    /// For callers that observe no input: every wait releases.
    public static let none = WaitAnswerLatch()

    private var answered: Set<String> = []
    private var unreadable: Set<String> = []

    public init() {}

    /// Approving a Claude or Copilot prompt sends no hook until the approved
    /// tool finishes, so only local input can suggest it was answered. Every
    /// other wait reports its answer with a hook and never consults input.
    public static func answerIsSilent(_ session: SessionRecord) -> Bool {
        session.state == .waiting && session.detail == SessionWaitDetail.approval
            && (session.tool == AgentID.claude.rawValue || session.tool == AgentID.copilot.rawValue)
    }

    /// A latch built from one observation, for one-shot callers.
    public static func observing(
        _ sessions: [SessionRecord],
        input: UserInputObservation
    ) -> WaitAnswerLatch {
        var latch = WaitAnswerLatch()
        latch.observe(sessions, input: input)
        return latch
    }

    /// Latches every silent wait that the input followed, and forgets waits
    /// that have ended or been replaced by a newer wait.
    public mutating func observe(_ sessions: [SessionRecord], input: UserInputObservation) {
        observe(sessions) { _ in input }
    }

    /// As above, with the input that could have answered each wait, such as
    /// only the input that went to that session's own app.
    public mutating func observe(
        _ sessions: [SessionRecord],
        input: (SessionRecord) -> UserInputObservation
    ) {
        let waits = sessions.filter(Self.answerIsSilent)
        answered.formIntersection(waits.map(Self.key))
        unreadable = []
        for wait in waits {
            switch input(wait) {
            case .unavailable:
                unreadable.insert(Self.key(wait))
            case .lastInput(let lastInput):
                if lastInput >= Self.earliestAnswer(to: wait) {
                    answered.insert(Self.key(wait))
                }
            }
        }
    }

    /// True when a Waiting session should be held and presented as Working.
    public func mayHaveBeenAnswered(_ session: SessionRecord) -> Bool {
        guard Self.answerIsSilent(session) else { return false }
        let key = Self.key(session)
        return unreadable.contains(key) || answered.contains(key)
    }

    public func holdsAwake(_ session: SessionRecord) -> Bool {
        switch session.state {
        case .working: true
        case .idle: false
        case .waiting: mayHaveBeenAnswered(session)
        }
    }

    private static func waitingSince(_ session: SessionRecord) -> Date {
        session.stateChangedAt ?? session.updatedAt
    }

    private static func earliestAnswer(to wait: SessionRecord) -> Date {
        let lead = wait.tool == AgentID.claude.rawValue
            ? answerLeadTolerance : copilotAnswerLeadTolerance
        return waitStart(wait).addingTimeInterval(-lead)
    }

    private static func waitStart(_ wait: SessionRecord) -> Date {
        // Persisted state edges round down to whole seconds. When the wait's
        // latest hook is its first, the precise hook time is the wait start.
        if let observed = wait.eventObservedAt,
           let changed = wait.stateChangedAt,
           observed.rounded(.down) == changed.timeIntervalSince1970.rounded(.down) {
            return Date(timeIntervalSince1970: observed)
        }
        return waitingSince(wait)
    }

    /// One wait: a new wait on the same session has a new transition.
    private static func key(_ session: SessionRecord) -> String {
        let since = waitingSince(session).timeIntervalSince1970
        return "\(session.id)\u{1F}\(session.stateTransitionID ?? "")\u{1F}\(since)"
    }
}

/// Decides whether to hold the Mac awake right now.
///
/// Pure on purpose: no clock, no IOKit, no file access. The caller supplies a
/// snapshot of real inputs once a second; tests use scripted sessions and
/// cover every rule without hardware or real waiting.
///
/// Precedence: safety guards first, then active work. Idle states never hold
/// the Mac awake.
public func decide(
    sessions: [SessionRecord],
    now: Date,
    settings: Settings,
    power: PowerState,
    waitAnswers: WaitAnswerLatch = .none,
    lowPowerModeOwnedByLetItBrew: Bool = false
) -> Decision {
    // 0. IMPORTANT 4: an untrusted reading must never be treated as a
    // confirmed "plugged in at 100%" — that would bypass the battery floor
    // below entirely. The standing rule is refuse-rather-than-guess, and the
    // safe direction here is the one that does NOT keep a laptop awake on an
    // unknown battery, so this takes precedence over everything else,
    // including active sessions.
    if !power.trusted {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "battery state unknown")
    }

    // 1. Connected-only mode releases on any battery level.
    if settings.onlyWhileConnectedToPower, power.onBattery {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "battery power")
    }

    // 2. Never flatten the battery, even mid-run.
    if power.onBattery, power.batteryPercent <= settings.batteryFloor {
        return Decision(holdSystem: false, holdLidClosed: false,
                        reason: "battery \(power.batteryPercent)%")
    }

    // 3. Low Power Mode releases active holds when the setting is enabled.
    // Low Power Mode that Let It Brew turned on for closed-lid work is not the
    // person's choice, so it must not release the hold that requested it.
    if settings.respectLowPowerMode, power.lowPowerModeEnabled,
       !lowPowerModeOwnedByLetItBrew {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "low power mode")
    }

    // 4. A shut lid traps heat with no airflow, so thermal pressure wins.
    if power.thermal == .serious || power.thermal == .critical {
        return Decision(holdSystem: false, holdLidClosed: false,
                        reason: "thermal pressure")
    }

    // 5. Working sessions hold, as do waits that local input may have answered.
    // Monitoring, and a subagent's own record, end once the session family
    // has been silent for its limit; see `MonitoringLease`.
    let familyEdges = MonitoringLease.latestEdges(sessions)
    let expiredLeases = sessions.filter {
        MonitoringLease.expired(
            $0, familyEdges: familyEdges, now: now, limit: settings.monitoringHoldLimit
        )
    }
    let working = sessions.count {
        waitAnswers.holdsAwake($0) && !expiredLeases.contains($0)
    }
    if working > 0 {
        return Decision(
            holdSystem: true,
            holdLidClosed: settings.lidClosedFollowsSession,
            holdDisplay: !settings.allowDisplaysToSleep,
            reason: "\(working) working"
        )
    }

    // 6. Completion has no grace period. The app applies this snapshot on its
    // existing one-second poll, so Stop/SessionEnd releases on the next poll.
    guard !sessions.isEmpty else {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "no agent sessions")
    }
    if sessions.contains(where: { $0.state == .waiting }) {
        return Decision(holdSystem: false, holdLidClosed: false, reason: "agents waiting for you")
    }
    if !expiredLeases.isEmpty {
        return Decision(holdSystem: false, holdLidClosed: false,
                        reason: "monitoring hold expired")
    }
    return Decision(holdSystem: false, holdLidClosed: false, reason: "all agents idle")
}

/// The bound on the monitoring sub-state. A session whose turn ended with
/// background work or scheduled crons, and a subagent's own record, hold only
/// while their session family is heard from: every hook from the parent or any
/// of its subagents renews the lease. Foreground turns are never leased.
public enum MonitoringLease {
    /// Whether a record holds only under the lease.
    public static func applies(to record: SessionRecord) -> Bool {
        guard record.state == .working else { return false }
        return HookSessionUpdater.isWaitingOnBackgroundWork(record)
            || HookRecordID(encoded: record.id)?.childID != nil
    }

    /// The family a record belongs to: its parent session's record ID.
    public static func familyID(of record: SessionRecord) -> String {
        guard let id = HookRecordID(encoded: record.id),
              let parent = HookRecordID(agent: id.agent, parentID: id.parentID)
        else { return record.id }
        return parent.encoded
    }

    /// The latest hook edge each family has written, over all its records.
    public static func latestEdges(_ records: [SessionRecord]) -> [String: Date] {
        records.reduce(into: [:]) { edges, record in
            let family = familyID(of: record)
            edges[family] = max(edges[family] ?? record.updatedAt, record.updatedAt)
        }
    }

    /// Whether a leased record's family has been silent for `limit`.
    public static func expired(
        _ record: SessionRecord,
        familyEdges: [String: Date],
        now: Date,
        limit: TimeInterval
    ) -> Bool {
        guard applies(to: record), limit.isFinite, limit > 0 else { return false }
        let edge = max(familyEdges[familyID(of: record)] ?? record.updatedAt, record.updatedAt)
        return now.timeIntervalSince(edge) >= limit
    }
}
