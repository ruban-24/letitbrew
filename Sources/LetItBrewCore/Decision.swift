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
    /// What wanted the hold, whether or not a power rule released it.
    public var wantedBy: HoldDemandCount
    /// The power rule that released the hold, whether or not anything
    /// wanted it.
    public var releasedBy: PowerRule?

    public init(
        holdSystem: Bool,
        holdLidClosed: Bool,
        holdDisplay: Bool = false,
        reason: String,
        wantedBy: HoldDemandCount = HoldDemandCount(),
        releasedBy: PowerRule? = nil
    ) {
        self.holdSystem = holdSystem
        self.holdLidClosed = holdLidClosed
        self.holdDisplay = holdDisplay
        self.reason = reason
        self.wantedBy = wantedBy
        self.releasedBy = releasedBy
    }
}

/// The power rules that release the hold, in `decide()`'s priority order.
public enum PowerRule: Equatable, Sendable {
    case unknownBattery
    case connectedPowerOnly
    /// Carries the floor setting, in percent.
    case batteryFloor(Int)
    case lowPowerMode
    case thermal
}

/// The agents and manual demands that want the Mac held awake.
public struct HoldDemandCount: Equatable, Sendable {
    /// Working agent sessions, including waits whose approved command runs.
    public var agents: Int
    /// Live `letitbrew hold` processes.
    public var holds: Int
    /// Manual sessions started from the menu whose deadline has not passed.
    public var manualSessions: Int

    public init(agents: Int = 0, holds: Int = 0, manualSessions: Int = 0) {
        self.agents = agents
        self.holds = holds
        self.manualSessions = manualSessions
    }

    public var isEmpty: Bool { agents == 0 && holds == 0 && manualSessions == 0 }

    /// "1 working", "1 hold", "manual session", or
    /// "2 working, manual session, 1 hold".
    var reason: String {
        var parts: [String] = []
        if agents > 0 { parts.append("\(agents) working") }
        if manualSessions > 0 { parts.append("manual session") }
        if holds > 0 { parts.append(holds == 1 ? "1 hold" : "\(holds) holds") }
        return parts.joined(separator: ", ")
    }
}

/// Which approval waits have an approved command running.
///
/// A Waiting session is blocked on the person, so it releases the hold. But
/// approving a Claude, Copilot, Gemini, or Qwen prompt fires no hook until the
/// approved tool finishes. Each of these agents runs an approved command as a
/// child process that leads its own process group, so cancelling can stop the
/// command's whole tree; the agent's own helpers, such as `caffeinate` and MCP
/// servers, stay in the agent's group. A wait therefore holds, and shows as
/// Working, while its agent has such a child that started with the wait and
/// has outlived the hooks, which also lead their own groups but finish fast.
///
/// Nothing is remembered between polls: the hold lasts only while the
/// command runs. Clicks and key presses never count, because they cannot tell
/// an answer from a stray click, and a stray click must not keep a Mac awake.
public struct RunningApprovals: Equatable, Sendable {
    /// A command started this long before a Claude permission notification
    /// still counts: Claude sends it about six seconds after the prompt
    /// appears, so it can land just after the approval.
    public static let answerLeadTolerance: TimeInterval = 3
    /// Copilot's notification timing is unverified, so a fast approval keeps
    /// a margin for hook delivery. Gemini and Qwen use the same margin.
    public static let copilotAnswerLeadTolerance: TimeInterval = 1
    /// Hooks finish well within this; an approved command still running this
    /// long after it started counts.
    public static let minimumRunTime: TimeInterval = 2

    /// For callers that read no processes: every wait releases.
    public static let none = RunningApprovals()

    private var running: Set<String> = []

    public init() {}

    /// Approving a Claude, Copilot, Gemini, or Qwen prompt sends no hook until
    /// the approved tool finishes, so only its running command can show it was
    /// approved. Every other wait reports its answer with a hook.
    public static func answerIsSilent(_ session: SessionRecord) -> Bool {
        session.state == .waiting && session.detail == SessionWaitDetail.approval
            && [AgentID.claude, .copilot, .gemini, .qwen]
                .contains { $0.rawValue == session.tool }
    }

    /// The agent processes whose children `observing` needs.
    public static func agentsToRead(_ sessions: [SessionRecord]) -> Set<Int32> {
        Set(sessions.filter(answerIsSilent).compactMap(\.pid))
    }

    /// Marks every silent wait whose agent is running a command started for
    /// it. A wait whose agent process is unknown releases.
    public static func observing(
        _ sessions: [SessionRecord],
        children: [AgentChildProcess],
        now: Date
    ) -> RunningApprovals {
        var result = RunningApprovals()
        for wait in sessions.filter(answerIsSilent) {
            guard let agent = wait.pid else { continue }
            let earliest = earliestStart(for: wait)
            let latest = now.addingTimeInterval(-minimumRunTime)
            if children.contains(where: {
                $0.parentPID == agent && $0.processGroup == $0.pid
                    && $0.startedAt >= earliest && $0.startedAt <= latest
            }) {
                result.running.insert(key(wait))
            }
        }
        return result
    }

    /// True when a Waiting session should be held and presented as Working.
    public func isRunning(_ session: SessionRecord) -> Bool {
        Self.answerIsSilent(session) && running.contains(Self.key(session))
    }

    public func holdsAwake(_ session: SessionRecord) -> Bool {
        switch session.state {
        case .working: true
        case .idle: false
        case .waiting: isRunning(session)
        }
    }

    private static func earliestStart(for wait: SessionRecord) -> Date {
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
        return wait.stateChangedAt ?? wait.updatedAt
    }

    /// One wait: a new wait on the same session has a new transition.
    private static func key(_ session: SessionRecord) -> String {
        let since = (session.stateChangedAt ?? session.updatedAt).timeIntervalSince1970
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
///
/// `demands` are manual keep-awake requests such as `letitbrew hold`. The
/// caller passes only live ones (see `HoldRecord.live`); each holds like a
/// Working session, under the same power rules, and is never bounded by
/// `MonitoringLease`. A manual session whose deadline is not after `now` is
/// ignored.
public func decide(
    sessions: [SessionRecord],
    demands: [KeepAwakeDemand] = [],
    now: Date,
    settings: Settings,
    power: PowerState,
    runningApprovals: RunningApprovals = .none,
    lowPowerModeOwnedByLetItBrew: Bool = false
) -> Decision {
    // Monitoring, and a subagent's own record, end once the session family
    // has been silent for its limit; see `MonitoringLease`.
    let familyEdges = MonitoringLease.latestEdges(sessions)
    let expiredLeases = sessions.filter {
        MonitoringLease.expired(
            $0, familyEdges: familyEdges, now: now, limit: settings.monitoringHoldLimit
        )
    }
    let wanted = HoldDemandCount(
        agents: sessions.count {
            runningApprovals.holdsAwake($0) && !expiredLeases.contains($0)
        },
        holds: demands.count { if case .hold = $0 { true } else { false } },
        manualSessions: demands.count {
            if case .manualSession(let deadline) = $0 { deadline.map { $0 > now } ?? true } else { false }
        }
    )
    func release(_ reason: String, _ rule: PowerRule) -> Decision {
        Decision(holdSystem: false, holdLidClosed: false, reason: reason, wantedBy: wanted,
                 releasedBy: rule)
    }

    // 0. IMPORTANT 4: an untrusted reading must never be treated as a
    // confirmed "plugged in at 100%" — that would bypass the battery floor
    // below entirely. The standing rule is refuse-rather-than-guess, and the
    // safe direction here is the one that does NOT keep a laptop awake on an
    // unknown battery, so this takes precedence over everything else,
    // including active sessions.
    if !power.trusted {
        return release("battery state unknown", .unknownBattery)
    }

    // 1. Connected-only mode releases on any battery level.
    if settings.onlyWhileConnectedToPower, power.onBattery {
        return release("battery power", .connectedPowerOnly)
    }

    // 2. Never flatten the battery, even mid-run.
    if power.onBattery, power.batteryPercent <= settings.batteryFloor {
        return release("battery \(power.batteryPercent)%", .batteryFloor(settings.batteryFloor))
    }

    // 3. Low Power Mode releases active holds when the setting is enabled.
    // Low Power Mode that Let It Brew turned on for closed-lid work is not the
    // person's choice, so it must not release the hold that requested it.
    if settings.respectLowPowerMode, power.lowPowerModeEnabled,
       !lowPowerModeOwnedByLetItBrew {
        return release("low power mode", .lowPowerMode)
    }

    // 4. A shut lid traps heat with no airflow, so thermal pressure wins.
    if power.thermal == .serious || power.thermal == .critical {
        return release("thermal pressure", .thermal)
    }

    // 5. Working sessions hold, as do waits whose approved command is
    // running, and live manual demands.
    if !wanted.isEmpty {
        return Decision(
            holdSystem: true,
            holdLidClosed: settings.lidClosedFollowsSession,
            holdDisplay: !settings.allowDisplaysToSleep,
            reason: wanted.reason,
            wantedBy: wanted
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
            var edge = record.updatedAt
            if let familyEdge = record.familyEdgeAt {
                edge = max(edge, Date(timeIntervalSince1970: familyEdge))
            }
            edges[family] = max(edges[family] ?? edge, edge)
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
