import Foundation

/// The JSON a hook delivers on stdin. The supported agents share enough
/// structural fields that one decoder can serve every adapter.
///
/// Every field is optional and unknown fields are ignored on purpose: both
/// tools add fields over time, and a decode failure here would mean a hook
/// that reports nothing.
public struct HookPayload: Decodable, Equatable, Sendable {
    public var sessionId: String?
    public var agentId: String?
    public var cwd: String?
    public var source: String?
    public var hasBackgroundTasks: Bool
    /// An absent snapshot cannot prove that the parent's background work ended.
    var hasBackgroundTaskSnapshot: Bool = false
    public var hookEventName: String?
    public var toolName: String?
    public var notificationType: String?
    public var errorRecoverable: Bool?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case camelSessionID = "sessionId"
        case agentID = "agent_id"
        case cwd
        case source
        case backgroundTasks = "background_tasks"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case errorRecoverable = "recoverable"
    }

    public init(
        sessionId: String? = nil,
        agentId: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        hasBackgroundTasks: Bool = false,
        hookEventName: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        errorRecoverable: Bool? = nil
    ) {
        self.sessionId = sessionId
        self.agentId = agentId
        self.cwd = cwd
        self.source = source
        self.hasBackgroundTasks = hasBackgroundTasks
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.notificationType = notificationType
        self.errorRecoverable = errorRecoverable
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionID)
            ?? values.decodeIfPresent(String.self, forKey: .camelSessionID)
        agentId = try values.decodeIfPresent(String.self, forKey: .agentID)
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd)
        source = try values.decodeIfPresent(String.self, forKey: .source)
        let backgroundTasks = try values.decodeIfPresent(
            [BackgroundTask].self, forKey: .backgroundTasks
        )
        hasBackgroundTaskSnapshot = backgroundTasks != nil
        hasBackgroundTasks = (backgroundTasks ?? []).contains(where: \.mayBeWorking)
        hookEventName = try values.decodeIfPresent(String.self, forKey: .hookEventName)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try values.decodeIfPresent(String.self, forKey: .notificationType)
        errorRecoverable = try values.decodeIfPresent(Bool.self, forKey: .errorRecoverable)
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

/// Read only lifecycle status, never task descriptions, commands or output.
/// Unknown or missing statuses remain conservative so a vendor schema change
/// cannot silently release the keep-awake hold during background work.
private struct BackgroundTask: Decodable {
    let status: String?

    private enum CodingKeys: String, CodingKey { case status }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        status = try? values.decode(String.self, forKey: .status)
    }

    var mayBeWorking: Bool {
        switch status {
        case "completed", "failed", "killed", "cancelled", "canceled", "idle": false
        default: true
        }
    }
}
