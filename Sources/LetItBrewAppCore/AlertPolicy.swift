import Foundation
import LetItBrewCore

/// What the person turned on in Settings → Alerts. Alerts are opt-in: a new
/// install and an update from 1.x both start with desktop alerts off.
public struct AlertSettings: Equatable, Sendable {
    public var desktopAlerts: Bool
    public var needsYou: Bool
    /// Agents and held commands that ran for 3 minutes or more.
    public var finished: Bool
    /// The hold released by the battery floor, connected-power-only, Low
    /// Power Mode, or heat.
    public var stoppedForPower: Bool
    /// The network stayed down for 60 seconds while the lid was closed and
    /// something was held.
    public var wifiDropped: Bool
    public var hideProjectNames: Bool
    /// ntfy is set up and a test has reached the server.
    public var phoneAlerts: Bool
    /// Send to the phone even while the person is at the Mac.
    public var alwaysSendToPhone: Bool

    public init(
        desktopAlerts: Bool = false,
        needsYou: Bool = true,
        finished: Bool = true,
        stoppedForPower: Bool = true,
        wifiDropped: Bool = false,
        hideProjectNames: Bool = false,
        phoneAlerts: Bool = false,
        alwaysSendToPhone: Bool = false
    ) {
        self.desktopAlerts = desktopAlerts
        self.needsYou = needsYou
        self.finished = finished
        self.stoppedForPower = stoppedForPower
        self.wifiDropped = wifiDropped
        self.hideProjectNames = hideProjectNames
        self.phoneAlerts = phoneAlerts
        self.alwaysSendToPhone = alwaysSendToPhone
    }
}

/// Whether the person is at the Mac. Desktop alerts ignore it; phone
/// alerts go out only when the person is away.
public struct AlertPresence: Equatable, Sendable {
    public let lidClosed: Bool
    public let screenLocked: Bool
    public let secondsSinceLastInput: TimeInterval
    /// An external display is active, so a closed lid may be a docked Mac.
    public let externalDisplay: Bool

    public init(
        lidClosed: Bool,
        screenLocked: Bool,
        secondsSinceLastInput: TimeInterval,
        externalDisplay: Bool = false
    ) {
        self.lidClosed = lidClosed
        self.screenLocked = screenLocked
        self.secondsSinceLastInput = secondsSinceLastInput
        self.externalDisplay = externalDisplay
    }

    public static let awayAfterNoInput: TimeInterval = 5 * 60

    /// Lid closed, screen locked, or five minutes with no keyboard or mouse.
    /// A closed lid with an external display is a docked Mac someone may be
    /// using, so there only the lock and the idle time count.
    public var isAway: Bool {
        (lidClosed && !externalDisplay) || screenLocked
            || secondsSinceLastInput >= Self.awayAfterNoInput
    }
}

public enum AlertWaitKind: Equatable, Sendable {
    case approval
    case answer
}

/// One session as alerts see it. There is deliberately no field for prompt
/// text, questions, tool names, or commands, so none can reach an alert. A
/// held command's alert can name its program, never its arguments.
public struct AlertSessionObservation: Equatable, Sendable {
    public let id: String
    /// The agent's tool identifier, such as "claude".
    public let agent: String
    /// The project folder's name.
    public let project: String
    /// Nil unless the session is Waiting on the person as the menu shows it:
    /// a wait whose approved command is running counts as Working.
    public let wait: AlertWaitKind?
    /// Whether the session is Working (or monitoring work it started) as the
    /// menu shows it. Never true while `wait` is set.
    public let working: Bool
    /// Whether the session is Idle: its turn is over. A session that is
    /// none of Working, Waiting, or Idle (a lapsed monitoring lease) has not
    /// finished.
    public let idle: Bool
    /// When the record last changed state.
    public let stateChangedAt: Date
    /// Brings the session's app forward when the alert is clicked.
    public let agentPID: Int32?

    public init(
        id: String,
        agent: String,
        project: String,
        wait: AlertWaitKind?,
        working: Bool = false,
        idle: Bool = false,
        stateChangedAt: Date,
        agentPID: Int32?
    ) {
        self.id = id
        self.agent = agent
        self.project = project
        self.wait = wait
        self.working = wait == nil && working
        self.idle = wait == nil && !self.working && idle
        self.stateChangedAt = stateChangedAt
        self.agentPID = agentPID
    }
}

public struct AlertSessionState: Equatable, Sendable {
    public let observation: AlertSessionObservation
    /// Start of the current unbroken Waiting stretch, as seen by polling.
    public let waitingSince: Date?
    /// Start of the current unbroken Working stretch, as seen by polling.
    public let workingSince: Date?
    /// This wait passed 30 seconds while the person was at the Mac, and the
    /// phone has not had its alert yet.
    var phoneOwed = false
}

/// One `letitbrew hold` as alerts see it.
public struct AlertHold: Equatable, Sendable {
    /// Unique per hold, even when a PID is reused.
    public let id: String
    /// The held command line, or what names a held process.
    public let label: String
    public let startedAt: Date
    /// A bare `letitbrew hold`, which ends at Ctrl-C with the person at the
    /// terminal, so its end is not news.
    public let endsAtTerminal: Bool

    public init(id: String, label: String, startedAt: Date, endsAtTerminal: Bool = false) {
        self.id = id
        self.label = label
        self.startedAt = startedAt
        self.endsAtTerminal = endsAtTerminal
    }

    /// A hold is its PID plus its start time, so a reused PID is a new hold.
    public init(_ record: HoldRecord) {
        self.init(
            id: "\(record.pid).\(record.startedAt.timeIntervalSince1970)",
            label: record.label,
            startedAt: record.startedAt,
            endsAtTerminal: record.label == HoldRecord.terminalLabel
        )
    }
}

/// A held command that exited and left its exit status.
public struct AlertHoldResult: Equatable, Sendable {
    public let hold: AlertHold
    public let endedAt: Date
    /// The command's exit code, or 128 + signal.
    public let exitStatus: Int32

    public init(hold: AlertHold, endedAt: Date, exitStatus: Int32) {
        self.hold = hold
        self.endedAt = endedAt
        self.exitStatus = exitStatus
    }
}

/// The hold and its surroundings at one poll.
public struct AlertMachineState: Equatable, Sendable {
    /// Whether Let It Brew is holding the Mac awake, after Pause.
    public var held: Bool
    /// Whether a Working session or a demand wants the hold, power rules
    /// aside. False while paused.
    public var holdWanted: Bool
    /// The power rule releasing the hold, from `decide()`.
    public var releasedBy: PowerRule?
    public var lidClosed: Bool
    /// Nil until the network has been read.
    public var networkReachable: Bool?

    public init(
        held: Bool = false,
        holdWanted: Bool = false,
        releasedBy: PowerRule? = nil,
        lidClosed: Bool = false,
        networkReachable: Bool? = nil
    ) {
        self.held = held
        self.holdWanted = holdWanted
        self.releasedBy = releasedBy
        self.lidClosed = lidClosed
        self.networkReachable = networkReachable
    }
}

/// The sessions and holds at one poll, with how long each session has been
/// Waiting or Working.
public struct AlertSnapshot: Equatable, Sendable {
    public let observedAt: Date
    public internal(set) var sessions: [AlertSessionState]
    /// Holds whose process is running.
    public let holds: [AlertHold]
    /// Held commands that have exited since the results were last read.
    public let endedHolds: [AlertHoldResult]
    /// Holds whose result some poll has seen, kept while a live record or
    /// result remains, so a live record that outlives its result never
    /// reads as a second ending.
    public let reportedHolds: Set<String>
    public let machine: AlertMachineState
    /// Start of the current network outage, as seen by polling: set by a
    /// drop from reachable while the lid is closed and the Mac held, and
    /// cleared when any of the three ends.
    public let networkDownSince: Date?

    /// A record's state edge alone cannot time a wait: an approved command
    /// shows the session as Working while the record stays Waiting, and once
    /// it exits the session is Waiting again with the old edge. So a wait is
    /// timed from when polling first saw it, never before the previous poll.
    public init(
        observedAt: Date,
        sessions: [AlertSessionObservation],
        holds: [AlertHold] = [],
        endedHolds: [AlertHoldResult] = [],
        machine: AlertMachineState = AlertMachineState(),
        previous: AlertSnapshot?
    ) {
        self.machine = machine
        self.observedAt = observedAt
        if machine.networkReachable == false, machine.lidClosed, machine.held {
            if let since = previous?.networkDownSince {
                networkDownSince = since
            } else if previous?.machine.networkReachable == true {
                networkDownSince = observedAt
            } else {
                networkDownSince = nil
            }
        } else {
            networkDownSince = nil
        }
        self.holds = holds
        self.endedHolds = endedHolds
        self.reportedHolds = Set(endedHolds.map(\.hold.id)).union(
            (previous?.reportedHolds ?? []).intersection(holds.map(\.id))
        )
        self.sessions = sessions.map { session in
            let before = previous?.sessions.first { $0.observation.id == session.id }
            let firstSeen = max(session.stateChangedAt, previous?.observedAt ?? .distantPast)
            if session.working {
                // Working is continuous while every poll sees it, whatever
                // the record's edges did in between.
                return AlertSessionState(
                    observation: session,
                    waitingSince: nil,
                    workingSince: before?.workingSince ?? firstSeen
                )
            }
            guard session.wait != nil else {
                return AlertSessionState(observation: session, waitingSince: nil, workingSince: nil)
            }
            if let before,
               let since = before.waitingSince,
               before.observation.stateChangedAt == session.stateChangedAt {
                return AlertSessionState(
                    observation: session,
                    waitingSince: since,
                    workingSince: nil,
                    phoneOwed: before.phoneOwed
                )
            }
            return AlertSessionState(observation: session, waitingSince: firstSeen, workingSince: nil)
        }
    }
}

public enum AlertKind: Equatable, Sendable {
    case needsYou
    case finished
    case stoppedForPower
    case wifiDropped
}

public enum AlertDestination: Hashable, Sendable {
    case desktop
    case phone
}

public struct Alert: Equatable, Sendable, Identifiable {
    /// Stable per episode, so a repeated delivery replaces rather than stacks.
    public let id: String
    public let kind: AlertKind
    public let destinations: Set<AlertDestination>
    public let title: String
    public let body: String
    public let sessionID: String
    public let agentPID: Int32?
}

public enum AlertPolicy {
    public static let needsYouDelay: TimeInterval = 30
    /// Shorter work never sends a finished alert.
    public static let finishedMinimum: TimeInterval = 3 * 60
    /// A shorter network outage never sends a Wi-Fi alert.
    public static let wifiDroppedDelay: TimeInterval = 60

    /// Alerts for what changed between two polls, with final wording. An
    /// alert fires on the poll that crosses its threshold, so reapplying a
    /// snapshot repeats nothing. Without a previous snapshot there is no
    /// crossing: launching never alerts for a wait already under way.
    ///
    /// A wait that crosses while the person is at the Mac goes to the phone
    /// once, later, if they become away while it is still waiting. `current`
    /// records that, so keep it as the next poll's `previous`.
    public static func alerts(
        previous: AlertSnapshot?,
        current: inout AlertSnapshot,
        presence: AlertPresence,
        settings: AlertSettings
    ) -> [Alert] {
        guard let previous else { return [] }
        let destinations = destinations(presence: presence, settings: settings)
        var alerts: [Alert] = []
        if settings.needsYou {
            alerts += needsYouAlerts(previous: previous, current: &current, presence: presence,
                                     destinations: destinations, settings: settings)
        }
        // Only the needs-you follow-up has to track anything with no channel.
        guard !destinations.isEmpty else { return alerts }
        if settings.finished {
            alerts += finishedSessionAlerts(previous: previous, current: current,
                                            destinations: destinations, settings: settings)
            alerts += finishedHoldAlerts(previous: previous, current: current,
                                         destinations: destinations, settings: settings)
        }
        if settings.stoppedForPower,
           let alert = stoppedAlert(previous: previous, current: current, destinations: destinations) {
            alerts.append(alert)
        }
        if settings.wifiDropped,
           let alert = wifiAlert(previous: previous, current: current, destinations: destinations) {
            alerts.append(alert)
        }
        return alerts
    }

    /// The hold was on at the previous poll and a power rule took it away
    /// while work still wanted it. Staying released is the same episode.
    private static func stoppedAlert(
        previous: AlertSnapshot,
        current: AlertSnapshot,
        destinations: Set<AlertDestination>
    ) -> Alert? {
        let machine = current.machine
        guard previous.machine.held, !machine.held, machine.holdWanted,
              let rule = machine.releasedBy
        else { return nil }
        let body: String
        switch rule {
        case .unknownBattery: return nil
        case .connectedPowerOnly: body = "It switched to battery power."
        case .batteryFloor(let floor): body = "Battery reached \(floor)%."
        case .lowPowerMode: body = "Low Power Mode turned on."
        case .thermal: body = "It got too warm."
        }
        return Alert(
            id: "stopped.\(current.observedAt.timeIntervalSince1970)",
            kind: .stoppedForPower,
            destinations: destinations,
            title: "Your Mac stopped keeping awake",
            body: body,
            sessionID: "",
            agentPID: nil
        )
    }

    /// The network has been unreachable for `wifiDroppedDelay`, with the
    /// lid closed and the Mac held throughout. Staying down is the same
    /// episode.
    private static func wifiAlert(
        previous: AlertSnapshot,
        current: AlertSnapshot,
        destinations: Set<AlertDestination>
    ) -> Alert? {
        guard let since = current.networkDownSince,
              current.observedAt.timeIntervalSince(since) >= wifiDroppedDelay
        else { return nil }
        if previous.networkDownSince == since,
           previous.observedAt.timeIntervalSince(since) >= wifiDroppedDelay {
            return nil
        }
        return Alert(
            id: "wifi.\(since.timeIntervalSince1970)",
            kind: .wifiDropped,
            destinations: destinations,
            title: "Wi-Fi dropped while your Mac was closed",
            body: "Agents may be stuck until it reconnects.",
            sessionID: "",
            agentPID: nil
        )
    }

    /// Where an alert goes. Every kind shares the same channels: desktop
    /// whenever desktop alerts are on; the phone only once ntfy is set up,
    /// and then only while the person is away unless they chose "Always
    /// send to phone".
    private static func destinations(
        presence: AlertPresence,
        settings: AlertSettings
    ) -> Set<AlertDestination> {
        var destinations: Set<AlertDestination> = []
        if settings.desktopAlerts { destinations.insert(.desktop) }
        if settings.phoneAlerts, settings.alwaysSendToPhone || presence.isAway {
            destinations.insert(.phone)
        }
        return destinations
    }

    /// A wait that crosses while the person is at the Mac is owed to the
    /// phone, which gets it once if they become away while it still waits.
    private static func needsYouAlerts(
        previous: AlertSnapshot,
        current: inout AlertSnapshot,
        presence: AlertPresence,
        destinations: Set<AlertDestination>,
        settings: AlertSettings
    ) -> [Alert] {
        var alerts: [Alert] = []
        for index in current.sessions.indices {
            let state = current.sessions[index]
            guard let since = state.waitingSince,
                  let wait = state.observation.wait,
                  current.observedAt.timeIntervalSince(since) >= needsYouDelay
            else { continue }
            let before = previous.sessions.first {
                $0.observation.id == state.observation.id && $0.waitingSince == since
            }
            let crossedBefore = before != nil
                && previous.observedAt.timeIntervalSince(since) >= needsYouDelay

            if !crossedBefore {
                if !destinations.isEmpty {
                    alerts.append(needsYou(state.observation, wait: wait, since: since,
                                           destinations: destinations, settings: settings))
                }
                current.sessions[index].phoneOwed =
                    !presence.isAway && !destinations.contains(.phone)
            } else if state.phoneOwed, settings.phoneAlerts, presence.isAway {
                alerts.append(needsYou(state.observation, wait: wait, since: since,
                                       destinations: [.phone], settings: settings))
                current.sessions[index].phoneOwed = false
            }
        }
        return alerts
    }

    /// A session that was Working at the previous poll and is now Idle or
    /// gone. Going Waiting, or a lapsed lease, is not finishing. The work
    /// ends at the Idle edge, or at the last poll that saw it Working if the
    /// session is gone.
    private static func finishedSessionAlerts(
        previous: AlertSnapshot,
        current: AlertSnapshot,
        destinations: Set<AlertDestination>,
        settings: AlertSettings
    ) -> [Alert] {
        previous.sessions.compactMap { before in
            guard let since = before.workingSince else { return nil }
            let after = current.sessions.first { $0.observation.id == before.observation.id }
            var end = previous.observedAt
            if let after {
                guard after.observation.idle else { return nil }
                end = min(max(after.observation.stateChangedAt, previous.observedAt), current.observedAt)
            }
            let worked = end.timeIntervalSince(since)
            guard worked >= finishedMinimum else { return nil }
            let session = before.observation
            var body = "Worked for \(minutes(worked)) min"
            if !settings.hideProjectNames, !session.project.isEmpty {
                body = "\(session.project) · " + body
            }
            return Alert(
                id: "finished.\(session.id).\(since.timeIntervalSince1970)",
                kind: .finished,
                destinations: destinations,
                title: "\(agentName(session.agent)) finished",
                body: body,
                sessionID: session.id,
                agentPID: session.agentPID
            )
        }
    }

    /// A held command reports its exit status; a hold that vanishes without
    /// one (`--pid`, or a killed CLI) is timed to the last poll that saw it.
    /// A bare hold's end is never alerted.
    private static func finishedHoldAlerts(
        previous: AlertSnapshot,
        current: AlertSnapshot,
        destinations: Set<AlertDestination>,
        settings: AlertSettings
    ) -> [Alert] {
        let reported = previous.reportedHolds
        let withStatus: [Alert] = current.endedHolds.compactMap { result in
            guard !reported.contains(result.hold.id) else { return nil }
            let ran = result.endedAt.timeIntervalSince(result.hold.startedAt)
            guard ran >= finishedMinimum else { return nil }
            let succeeded = result.exitStatus == 0
            let verb = succeeded ? "finished" : "failed"
            return holdAlert(
                result.hold,
                title: "\(holdName(result.hold, settings)) \(verb)",
                body: "\(succeeded ? "Succeeded" : "Failed") after \(minutes(ran)) min",
                destinations: destinations
            )
        }
        let stillKnown = Set(current.holds.map(\.id))
            .union(current.endedHolds.map(\.hold.id))
            .union(reported)
        let vanished: [Alert] = previous.holds.compactMap { hold in
            guard !stillKnown.contains(hold.id), !hold.endsAtTerminal else { return nil }
            let ran = previous.observedAt.timeIntervalSince(hold.startedAt)
            guard ran >= finishedMinimum else { return nil }
            return holdAlert(
                hold,
                title: "\(holdName(hold, settings)) finished",
                body: "Finished after \(minutes(ran)) min",
                destinations: destinations
            )
        }
        return withStatus + vanished
    }

    private static func holdName(_ hold: AlertHold, _ settings: AlertSettings) -> String {
        let program = programName(hold.label)
        return settings.hideProjectNames || program.isEmpty ? "A held command" : program
    }

    /// The held program without its arguments, which can hold secrets: the
    /// label's first word with any folder path removed. A `--pid` hold's
    /// "Process N" has no arguments and stays whole. A first word the label's
    /// length limit cut short names no program, so it is empty.
    private static func programName(_ label: String) -> String {
        let words = label.split(separator: " ")
        if words.count == 2, let pid = Int32(words[1]),
           label == HoldRecord.processLabel(pid: pid) {
            return label
        }
        guard let first = words.first, !first.hasSuffix("…") else { return "" }
        return first.split(separator: "/").last.map(String.init) ?? ""
    }

    private static func holdAlert(
        _ hold: AlertHold,
        title: String,
        body: String,
        destinations: Set<AlertDestination>
    ) -> Alert {
        Alert(
            id: "finished.hold.\(hold.id)",
            kind: .finished,
            destinations: destinations,
            title: title,
            body: body,
            sessionID: hold.id,
            agentPID: nil
        )
    }

    /// Whole minutes, rounded down.
    private static func minutes(_ duration: TimeInterval) -> Int {
        Int(duration / 60)
    }

    private static func needsYou(
        _ session: AlertSessionObservation,
        wait: AlertWaitKind,
        since: Date,
        destinations: Set<AlertDestination>,
        settings: AlertSettings
    ) -> Alert {
        var body = switch wait {
        case .approval: "Waiting for your approval"
        case .answer: "Waiting for your answer"
        }
        if !settings.hideProjectNames, !session.project.isEmpty {
            body = "\(session.project) · " + body
        }
        return Alert(
            id: "needs-you.\(session.id).\(since.timeIntervalSince1970)",
            kind: .needsYou,
            destinations: destinations,
            title: "\(agentName(session.agent)) needs you",
            body: body,
            sessionID: session.id,
            agentPID: session.agentPID
        )
    }

    private static func agentName(_ tool: String) -> String {
        AgentID(rawValue: tool)?.displayName ?? "An agent"
    }
}

/// The one-time menu tip that offers alerts after updating.
public enum AlertsTipPolicy {
    public static let title = "Get alerts when an agent needs you?"
    public static let detail = "A desktop notification when an agent waits on you for 30 seconds."

    public static func isShown(dismissed: Bool, desktopAlerts: Bool) -> Bool {
        !dismissed && !desktopAlerts
    }
}
