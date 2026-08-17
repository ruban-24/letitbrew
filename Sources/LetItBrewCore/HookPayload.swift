import Foundation

/// The JSON a hook delivers on stdin. Claude Code and Codex use the same
/// field names, so one decoder serves both.
///
/// Every field is optional and unknown fields are ignored on purpose: both
/// tools add fields over time, and a decode failure here would mean a hook
/// that reports nothing.
public struct HookPayload: Decodable, Equatable, Sendable {
    public var sessionId: String?
    public var parentConversationId: String?
    public var agentId: String?
    public var subagentId: String?
    public var cwd: String?
    public var source: String?
    public var hasBackgroundTasks: Bool
    public var hookEventName: String?
    public var toolName: String?
    public var notificationType: String?
    public var transcriptPath: String?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case conversationID = "conversation_id"
        case parentConversationID = "parent_conversation_id"
        case camelSessionID = "sessionId"
        case agentID = "agent_id"
        case subagentID = "subagent_id"
        case cwd
        case workspaceRoots = "workspace_roots"
        case source
        case backgroundTasks = "background_tasks"
        case hookEventName = "hook_event_name"
        case toolName = "tool_name"
        case notificationType = "notification_type"
        case transcriptPath = "transcript_path"
    }

    public init(
        sessionId: String? = nil,
        parentConversationId: String? = nil,
        agentId: String? = nil,
        subagentId: String? = nil,
        cwd: String? = nil,
        source: String? = nil,
        hasBackgroundTasks: Bool = false,
        hookEventName: String? = nil,
        toolName: String? = nil,
        notificationType: String? = nil,
        transcriptPath: String? = nil
    ) {
        self.sessionId = sessionId
        self.parentConversationId = parentConversationId
        self.agentId = agentId
        self.subagentId = subagentId
        self.cwd = cwd
        self.source = source
        self.hasBackgroundTasks = hasBackgroundTasks
        self.hookEventName = hookEventName
        self.toolName = toolName
        self.notificationType = notificationType
        self.transcriptPath = transcriptPath
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try values.decodeIfPresent(String.self, forKey: .sessionID)
            ?? values.decodeIfPresent(String.self, forKey: .conversationID)
            ?? values.decodeIfPresent(String.self, forKey: .camelSessionID)
            ?? values.decodeIfPresent(String.self, forKey: .parentConversationID)
        parentConversationId = try values.decodeIfPresent(
            String.self, forKey: .parentConversationID
        )
        agentId = try values.decodeIfPresent(String.self, forKey: .agentID)
        subagentId = try values.decodeIfPresent(String.self, forKey: .subagentID)
        let roots = try values.decodeIfPresent([String].self, forKey: .workspaceRoots)
        cwd = try values.decodeIfPresent(String.self, forKey: .cwd) ?? roots?.first
        source = try values.decodeIfPresent(String.self, forKey: .source)
        hasBackgroundTasks = !(try values.decodeIfPresent(
            [BackgroundTask].self, forKey: .backgroundTasks
        ) ?? []).isEmpty
        hookEventName = try values.decodeIfPresent(String.self, forKey: .hookEventName)
        toolName = try values.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try values.decodeIfPresent(String.self, forKey: .notificationType)
        transcriptPath = try values.decodeIfPresent(String.self, forKey: .transcriptPath)
    }

    public func recordID(agent: AgentID, event: String) -> String? {
        func nonempty(_ value: String?) -> String? {
            value.flatMap { $0.isEmpty ? nil : $0 }
        }

        let isSubagentEdge = event == "SubagentStart" || event == "SubagentStop"
        let parent = isSubagentEdge
            ? (nonempty(parentConversationId) ?? nonempty(sessionId))
            : nonempty(sessionId)
        guard let parent else { return nil }
        let child = agent == .cursor
            ? (nonempty(subagentId) ?? nonempty(agentId))
            : (nonempty(agentId) ?? nonempty(subagentId))
        guard !isSubagentEdge || child != nil else { return nil }
        return HookRecordID(agent: agent, parentID: parent, childID: child)?.encoded
    }
}

/// Decodes only the structural presence of an object in `background_tasks`.
/// Unknown task fields are intentionally discarded.
private struct BackgroundTask: Decodable {}
