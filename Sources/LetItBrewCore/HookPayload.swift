import Foundation

/// The JSON a hook delivers on stdin. The supported agents share enough
/// structural fields that one decoder can serve every adapter.
///
/// Every field is optional and unknown fields are ignored on purpose: both
/// tools add fields over time, and a decode failure here would mean a hook
/// that reports nothing.
public struct HookPayload: Decodable, Equatable, Sendable {
    /// What kind of background work a Claude `Stop` or `SubagentStop`
    /// snapshot still reports. Only each task's lifecycle `type` and
    /// `status` are read.
    public enum BackgroundWork: Equatable, Sendable {
        /// No task may still be working.
        case none
        /// Only shells and monitors remain. The turn itself has ended, so
        /// this hold is bounded; see `Settings.monitoringHoldLimit`.
        case shellOnly
        /// A subagent, teammate, workflow, or task of an unrecognized type
        /// may still be working. Holds like a running turn.
        case agent
    }

    /// One background task reduced to its lifecycle facts.
    public struct BackgroundTask: Equatable, Sendable {
        public var id: String?
        /// `shell` and `monitor` are bounded work; every other or missing
        /// type is treated as agent work so a vendor schema change cannot
        /// weaken a hold.
        public var isShell: Bool
        public var mayBeWorking: Bool

        public init(id: String? = nil, isShell: Bool = false, mayBeWorking: Bool = true) {
            self.id = id
            self.isShell = isShell
            self.mayBeWorking = mayBeWorking
        }
    }

    public var sessionId: String?
    public var agentId: String?
    public var cwd: String?
    public var source: String?
    /// `manual` or `auto` on Claude compaction hooks.
    public var trigger: String?
    /// The `background_tasks` snapshot, or nil when the hook carried none.
    /// An absent snapshot cannot prove that the parent's background work ended.
    public var backgroundTasks: [BackgroundTask]?
    public var hookEventName: String?
    public var toolName: String?
    public var notificationType: String?
    public var errorRecoverable: Bool?
    /// How many scheduled session crons Claude's `Stop` reports, or nil when
    /// the hook carried no `session_crons` array. Only the count is read,
    /// never a cron's prompt or schedule.
    public var sessionCronCount: Int?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case camelSessionID = "sessionId"
        case agentID = "agent_id"
        case cwd
        case source
        case trigger
        case backgroundTasks = "background_tasks"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case errorRecoverable = "recoverable"
        case sessionCrons = "session_crons"
    }

    public init(
        sessionId: String? = nil,
        agentId: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        trigger: String? = nil,
        backgroundTasks: [BackgroundTask]? = nil,
        hookEventName: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        errorRecoverable: Bool? = nil,
        sessionCronCount: Int? = nil
    ) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.cwd = cwd
        self.source = source
        self.trigger = trigger
        self.backgroundTasks = backgroundTasks
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.notificationType = notificationType
        self.errorRecoverable = errorRecoverable
        self.sessionCronCount = sessionCronCount
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionID)
            ?? values.decodeIfPresent(String.self, forKey: .camelSessionID)
        agentId = try values.decodeIfPresent(String.self, forKey: .agentID)
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        trigger = try values.decodeIfPresent(String.self, forKey: .trigger)
        backgroundTasks = try values.decodeIfPresent(
            [WireBackgroundTask].self, forKey: .backgroundTasks
        )?.map(\.summary)
        hookEventName = try values.decodeIfPresent(String.self, forKey: .hookEventName)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try values.decodeIfPresent(String.self, forKey: .notificationType)
        errorRecoverable = try values.decodeIfPresent(Bool.self, forKey: .errorRecoverable)
        sessionCronCount = (try? values.decodeIfPresent(
            [OpaqueJSONValue].self, forKey: .sessionCrons
        ))?.map(\.count)
    }

    /// Whether the session has scheduled crons that will start more turns.
    /// Claude may omit an empty `session_crons` array, so only a non-empty
    /// one counts.
    public var hasSessionCrons: Bool { (sessionCronCount ?? 0) > 0 }

    /// Whether the hook carried a `background_tasks` array at all.
    public var hasBackgroundTaskSnapshot: Bool { backgroundTasks != nil }

    /// Whether any reported task may still be working.
    public var hasBackgroundTasks: Bool { backgroundWork != .none }

    /// The strongest kind of work the snapshot still reports.
    public var backgroundWork: BackgroundWork { backgroundWork(excludingTaskID: nil) }

    /// The snapshot's work with one task left out. A backgrounded subagent's
    /// own `SubagentStop` snapshot still lists that subagent as running, so a
    /// parent reconciliation must not count the child that just finished.
    public func backgroundWork(excludingTaskID excluded: String?) -> BackgroundWork {
        var work = BackgroundWork.none
        for task in backgroundTasks ?? [] where task.mayBeWorking {
            if let excluded, task.id == excluded { continue }
            if !task.isShell { return .agent }
            work = .shellOnly
        }
        return work
    }

    /// IDs of every task the snapshot reports as possibly working, or nil when
    /// the snapshot is absent or any entry lacks an ID. Only a complete
    /// inventory may prove that an unlisted child has finished.
    public var runningBackgroundTaskIDs: Set<String>? {
        guard let backgroundTasks else { return nil }
        var ids: Set<String> = []
        for task in backgroundTasks {
            guard let id = task.id, !id.isEmpty else { return nil }
            if task.mayBeWorking { ids.insert(id) }
        }
        return ids
    }

    public func recordID(agent: AgentID, event: String) -> String? {
        func nonempty(_ value: String?) -> String? {
            value.flatMap { $0.isEmpty ? nil : $0 }
        }

        let isSubagentEdge = event == "SubagentStart" || event == "SubagentStop"
        let parent = nonempty(sessionId)
        guard let parent else { return nil }
        let child = nonempty(agentId)
        guard !isSubagentEdge || child != nil else { return nil }
        return HookRecordID(agent: agent, parentID: parent, childID: child)?.encoded
    }
}

/// Read only lifecycle identity, type, and status: never task descriptions,
/// commands, or output. Unknown or missing types and statuses remain
/// conservative so a vendor schema change cannot silently release the
/// keep-awake hold during background work.
private struct WireBackgroundTask: Decodable {
    let id: String?
    let type: String?
    let status: String?

    private enum CodingKeys: String, CodingKey { case id, type, status }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try? values.decode(String.self, forKey: .id)
        type = try? values.decode(String.self, forKey: .type)
        status = try? values.decode(String.self, forKey: .status)
    }

    /// Claude labels bounded, non-agent work `shell` and `monitor`; some
    /// builds report commands as `local_bash` or `background_shell`.
    private static let shellTypes: Set<String> = [
        "shell", "monitor", "local_bash", "background_shell",
    ]

    /// Statuses that mean a task can no longer be working.
    private static let terminalStatuses: Set<String> = [
        "idle", "done", "success", "succeeded", "complete", "completed", "finished",
        "failed", "error", "terminated", "exited", "aborted", "expired", "skipped",
        "crashed", "killed", "cancelled", "canceled", "timed_out",
    ]

    var summary: HookPayload.BackgroundTask {
        let normalizedType = type?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        let normalizedStatus = status?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        return HookPayload.BackgroundTask(
            id: id,
            isShell: Self.shellTypes.contains(normalizedType),
            mayBeWorking: !Self.terminalStatuses.contains(normalizedStatus)
        )
    }
}

/// Any JSON value, decoded without reading it, so an array can be counted
/// without keeping its contents.
private struct OpaqueJSONValue: Decodable {
    init(from decoder: Decoder) throws {}
}
