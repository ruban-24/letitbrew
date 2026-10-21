import Foundation
import LetItBrewCore

public enum MenuSessionState: Equatable, Sendable {
    case working
    case waitingForAnswer
    case waitingForApproval
    case idle

    /// Maps a record's state for presentation. A wait that local input may
    /// have answered holds as Working, so it is shown as Working too.
    public static func resolve(
        _ record: SessionRecord,
        waitAnswers: WaitAnswerLatch
    ) -> MenuSessionState {
        switch record.state {
        case .working:
            return .working
        case .idle:
            return .idle
        case .waiting:
            if waitAnswers.mayHaveBeenAnswered(record) {
                return .working
            }
            return record.detail == SessionWaitDetail.approval
                ? .waitingForApproval
                : .waitingForAnswer
        }
    }

    var isListed: Bool {
        self != .idle
    }

    public var isWaiting: Bool {
        self == .waitingForAnswer || self == .waitingForApproval
    }

    var text: String {
        switch self {
        case .working: "Working"
        case .waitingForAnswer: "Waiting for your answer"
        case .waitingForApproval: "Needs your approval"
        case .idle: "Idle"
        }
    }
}

public enum MenuSnapshotOrderPolicy {
    public static func shouldApply(
        candidateObservedAt: Date,
        latestAppliedAt: Date?
    ) -> Bool {
        guard let latestAppliedAt else { return true }
        return candidateObservedAt >= latestAppliedAt
    }
}

public struct MenuSessionSnapshot: Sendable {
    public let sessions: [SessionRecord]
    public let readStartedAt: Date
    public let now: Date

    public static func read(
        loadRecords: () -> [SessionRecord],
        now: () -> Date = Date.init,
        ttl: TimeInterval
    ) -> MenuSessionSnapshot {
        let startedAt = now()
        let records = loadRecords()
        // A hook may be written after the read starts. Judge freshness after
        // loading, while retaining the start time to reject stale async reads.
        let completedAt = now()
        return MenuSessionSnapshot(
            sessions: SessionStore.recent(records: records, now: completedAt, ttl: ttl),
            readStartedAt: startedAt,
            now: completedAt
        )
    }
}

public struct SessionMenuInput: Sendable {
    public let id: String
    public let tool: String
    public let project: String
    public let repositoryPath: String
    public let state: MenuSessionState
    public let activeWorkingTime: TimeInterval
    public let updatedAt: Date
    public let agentPID: Int32?

    public init(
        id: String,
        tool: String,
        project: String,
        repositoryPath: String,
        state: MenuSessionState,
        activeWorkingTime: TimeInterval,
        updatedAt: Date,
        agentPID: Int32? = nil
    ) {
        self.id = id
        self.tool = tool
        self.project = project
        self.repositoryPath = repositoryPath
        self.state = state
        self.activeWorkingTime = activeWorkingTime
        self.updatedAt = updatedAt
        self.agentPID = agentPID
    }
}

public struct MenuSessionPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let toolID: String
    public let toolName: String
    public let project: String
    public let repositoryID: String
    public let stateText: String
    public let activeTimeText: String
    public let updatedAt: Date
    public let isWaiting: Bool
    /// The agent process, for bringing its app forward. Nil when unknown.
    public let agentPID: Int32?

    public var accessibilityState: String {
        stateText
    }
}

public struct MenuRepositorySessionPresentation: Identifiable, Equatable, Sendable {
    public let session: MenuSessionPresentation
    public let shortID: String

    public var id: String { session.id }
}

public struct MenuRepositoryPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let project: String
    public let summaryText: String
    public let sessionCountText: String
    public let sessions: [MenuRepositorySessionPresentation]
}

public enum MenuRepositoryLayoutItem: Identifiable, Equatable, Sendable {
    public enum ID: Hashable, Sendable {
        case header(String)
        case session(String)
    }

    case header(MenuRepositoryPresentation)
    case session(MenuRepositorySessionPresentation, displaysShortID: Bool)

    public var id: ID {
        switch self {
        case .header(let group): .header(group.id)
        case .session(let item, _): .session(item.id)
        }
    }

    public var shortSessionID: String? {
        switch self {
        case .header: nil
        case .session(let item, let displaysShortID):
            displaysShortID ? item.shortID : nil
        }
    }

    public var groupedProject: String? {
        switch self {
        case .header: nil
        case .session(let item, let displaysShortID):
            displaysShortID ? item.session.project : nil
        }
    }

    public var isSession: Bool {
        if case .session = self { return true }
        return false
    }
}

public enum MenuSessionPresentationPolicy {
    /// Keep surviving rows in their presented order and append new Working or
    /// Waiting sessions. Recency only chooses the initial order and orders
    /// newcomers. A session moving between Working and Waiting keeps its row.
    public static func rows(
        from inputs: [SessionMenuInput],
        now _: Date,
        previousIDs: [String] = []
    ) -> [MenuSessionPresentation] {
        let ranks = Dictionary(uniqueKeysWithValues: previousIDs.enumerated().map { ($1, $0) })
        return inputs
            .filter { $0.state.isListed }
            .map { input in
                MenuSessionPresentation(
                id: input.id,
                toolID: input.tool.lowercased(),
                toolName: displayTool(input.tool),
                project: input.project.isEmpty ? "Unknown project" : input.project,
                repositoryID: input.repositoryPath,
                stateText: input.state.text,
                activeTimeText: duration(input.activeWorkingTime) + " active",
                updatedAt: input.updatedAt,
                isWaiting: input.state.isWaiting,
                agentPID: input.agentPID
            )
            }
            .sorted {
                let lhsRank = ranks[$0.id] ?? .max
                let rhsRank = ranks[$1.id] ?? .max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                if $0.updatedAt != $1.updatedAt {
                    return $0.updatedAt > $1.updatedAt
                }
                return $0.id < $1.id
            }
    }

    private static func displayTool(_ tool: String) -> String {
        let trimmedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTool.isEmpty else { return "Unknown agent" }

        return AgentID(rawValue: trimmedTool.lowercased())?.displayName
            ?? trimmedTool.capitalized
    }

    private static func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval))
        if totalSeconds < 60 { return "<1m" }
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let totalHours = totalMinutes / 60
        let remainingMinutes = totalMinutes % 60
        if totalHours < 24 {
            return remainingMinutes == 0
                ? "\(totalHours)h"
                : "\(totalHours)h \(remainingMinutes)m"
        }
        let days = totalHours / 24
        let remainingHours = totalHours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }
}

public enum MenuRepositoryPresentationPolicy {
    /// Folder order is independent of which child most recently emitted a hook.
    public static func groups(
        from rows: [MenuSessionPresentation],
        previousIDs: [String] = []
    ) -> [MenuRepositoryPresentation] {
        let ranks = Dictionary(uniqueKeysWithValues: previousIDs.enumerated().map { ($1, $0) })
        return Dictionary(grouping: rows, by: \.repositoryID)
            .map { repositoryID, sessions in
                // Grouping preserves the stabilized row order; hook activity
                // must not independently reshuffle children within a folder.
                let shortIDs = uniqueShortIDs(for: sessions.map(\.id))
                return MenuRepositoryPresentation(
                    id: repositoryID,
                    project: sessions.first?.project ?? "Unknown project",
                    summaryText: summary(for: sessions),
                    sessionCountText: sessionCount(for: sessions),
                    sessions: sessions.map {
                        MenuRepositorySessionPresentation(
                            session: $0,
                            shortID: shortIDs[$0.id] ?? $0.id
                        )
                    }
                )
            }
            .sorted {
                let lhsRank = ranks[$0.id] ?? .max
                let rhsRank = ranks[$1.id] ?? .max
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return groupOrder($0, $1)
            }
    }

    private static func groupOrder(
        _ lhs: MenuRepositoryPresentation,
        _ rhs: MenuRepositoryPresentation
    ) -> Bool {
        let lhsUpdated = lhs.sessions.map(\.session.updatedAt).max() ?? .distantPast
        let rhsUpdated = rhs.sessions.map(\.session.updatedAt).max() ?? .distantPast
        if lhsUpdated != rhsUpdated { return lhsUpdated > rhsUpdated }
        return lhs.id < rhs.id
    }

    private static func sessionCount(for sessions: [MenuSessionPresentation]) -> String {
        let waiting = sessions.count(where: \.isWaiting)
        let working = sessions.count - waiting
        return [
            working > 0 ? "\(working) working" : nil,
            waiting > 0 ? "\(waiting) waiting" : nil,
        ].compactMap { $0 }.joined(separator: " · ")
    }

    private static func summary(for sessions: [MenuSessionPresentation]) -> String {
        Dictionary(grouping: sessions, by: \.toolName)
            .map { name, sessions in (name, sessions.count) }
            .sorted { lhs, rhs in
                let lhsRank = agentRank(lhs.0)
                let rhsRank = agentRank(rhs.0)
                if lhsRank != rhsRank { return lhsRank < rhsRank }
                return lhs.0 < rhs.0
            }
            .map { "\($0.1) \($0.0)" }
            .joined(separator: " · ")
    }

    private static func agentRank(_ name: String) -> Int {
        AgentID.allCases.firstIndex { $0.displayName == name } ?? .max
    }

    private static func uniqueShortIDs(for ids: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in ids {
            var length = min(8, id.count)
            while length < id.count,
                  ids.contains(where: {
                      $0 != id && $0.prefix(length) == id.prefix(length)
                  }) {
                length += 1
            }
            result[id] = String(id.prefix(length))
        }
        return result
    }
}

public enum MenuRepositoryLayoutPolicy {
    public static func items(
        for group: MenuRepositoryPresentation,
        isExpanded: Bool
    ) -> [MenuRepositoryLayoutItem] {
        guard group.sessions.count > 1 || isExpanded else {
            return group.sessions.map {
                .session($0, displaysShortID: false)
            }
        }

        var items: [MenuRepositoryLayoutItem] = [.header(group)]
        if isExpanded {
            items.append(contentsOf: group.sessions.map {
                .session($0, displaysShortID: true)
            })
        }
        return items
    }
}

public struct MenuRepositoryExpansionState: Equatable, Sendable {
    public let expandedRepositoryID: String?
    public let initialized: Bool

    public init(expandedRepositoryID: String?, initialized: Bool) {
        self.expandedRepositoryID = expandedRepositoryID
        self.initialized = initialized
    }
}

public enum MenuRepositoryExpansionPolicy {
    public static func initialExpandedID(
        in groups: [MenuRepositoryPresentation]
    ) -> String? {
        groups.first { $0.sessions.count > 1 }?.id
    }

    public static func toggle(current: String?, requested: String) -> String? {
        current == requested ? nil : requested
    }

    public static func reconcile(
        current: String?,
        groups: [MenuRepositoryPresentation]
    ) -> String? {
        guard let current,
              groups.contains(where: { $0.id == current && !$0.sessions.isEmpty })
        else { return nil }
        return current
    }

    public static func updatedState(
        current: MenuRepositoryExpansionState,
        hasLoadedSnapshot: Bool,
        groups: [MenuRepositoryPresentation]
    ) -> MenuRepositoryExpansionState {
        guard hasLoadedSnapshot else { return current }
        guard current.initialized else {
            return MenuRepositoryExpansionState(
                expandedRepositoryID: initialExpandedID(in: groups),
                initialized: true
            )
        }
        return MenuRepositoryExpansionState(
            expandedRepositoryID: reconcile(
                current: current.expandedRepositoryID,
                groups: groups
            ),
            initialized: true
        )
    }
}

public enum MenuActivityViewportMetrics {
    public static func height(for items: [MenuRepositoryLayoutItem]) -> CGFloat {
        min(items.reduce(CGFloat.zero) { partialResult, item in
            partialResult + (item.isSession ? 60 : 54)
        } + CGFloat(max(0, items.count - 1) * 2), 302)
    }
}

public enum MenuHeaderCopy {
    public enum ReleaseConstraint: Equatable, Sendable {
        case battery(percent: Int)
        case connectedPowerOnly
        case lowPowerMode
        case thermal
        case powerUnavailable

        fileprivate var message: String {
            switch self {
            case .battery:
                "Battery limit reached"
            case .connectedPowerOnly:
                "Running on battery"
            case .lowPowerMode:
                "Low Power Mode is on"
            case .thermal:
                "Mac is too warm"
            case .powerUnavailable:
                "Power status unavailable"
            }
        }
    }

    public static func resolve(
        isPaused: Bool,
        isKeepingAwake: Bool,
        releaseConstraint: ReleaseConstraint? = nil,
        isWaitingForYou: Bool = false
    ) -> String {
        if isPaused { return "Let It Brew is paused" }
        if isKeepingAwake { return "Keeping your Mac awake" }
        if let releaseConstraint { return releaseConstraint.message }
        if isWaitingForYou { return "Agents are waiting for you" }
        return "Watching for agents"
    }
}

public struct MenuBatteryPresentation: Equatable, Sendable {
    public let text: String
    public let isAttention: Bool

    public init(text: String, isAttention: Bool) {
        self.text = text
        self.isAttention = isAttention
    }
}

public enum MenuBatteryIconPolicy {
    public static func systemImageName(percent: Int) -> String {
        switch min(100, max(0, percent)) {
        case 88...:
            "battery.100percent"
        case 63...:
            "battery.75percent"
        case 38...:
            "battery.50percent"
        case 13...:
            "battery.25percent"
        default:
            "battery.0percent"
        }
    }
}

public enum MenuBatteryPresentationPolicy {
    public static func resolve(
        power: PowerState,
        batteryFloor: Int,
        releaseConstraint: MenuHeaderCopy.ReleaseConstraint?
    ) -> MenuBatteryPresentation? {
        if releaseConstraint == .lowPowerMode {
            return MenuBatteryPresentation(
                text: "Low Power Mode released the sleep hold",
                isAttention: true
            )
        }

        guard power.onBattery else { return nil }

        if case .battery(let percent) = releaseConstraint {
            return MenuBatteryPresentation(
                text: "Battery \(percent)% · Sleep hold stops below \(batteryFloor)%",
                isAttention: true
            )
        }

        if releaseConstraint == .connectedPowerOnly {
            return MenuBatteryPresentation(
                text: "Battery power released the sleep hold",
                isAttention: true
            )
        }

        return MenuBatteryPresentation(
            text: "Battery \(power.batteryPercent)% · Sleep hold stops below \(batteryFloor)%",
            isAttention: false
        )
    }
}

public enum MenuSupplementaryRow: Equatable, Sendable {
    case holdReleaseFailure(String)
    case battery(MenuBatteryPresentation)
    case update(StableUpdateVersion)
}

public enum MenuSupplementaryRowPolicy {
    public static func rows(
        holdReleaseFailure: String?,
        availableVersion: StableUpdateVersion?
    ) -> [MenuSupplementaryRow] {
        var rows: [MenuSupplementaryRow] = []
        if let holdReleaseFailure {
            rows.append(.holdReleaseFailure(holdReleaseFailure))
        }
        if let availableVersion {
            rows.append(.update(availableVersion))
        }
        return rows
    }
}

public enum MenuHeaderDetailContext: Sendable {
    case awake
    case idle
    case paused
}

public enum MenuHeaderDetailCopy {
    public static func resolve(
        context: MenuHeaderDetailContext,
        rows: [MenuSessionPresentation]
    ) -> String {
        switch context {
        case .awake:
            let workingCount = rows.count
            if workingCount == 1 { return "1 agent is working" }
            if workingCount > 1 { return "\(workingCount) agents are working" }
            return "No agents are working"
        case .idle:
            return "Your Mac can sleep normally"
        case .paused:
            return "Agents will not keep your Mac awake"
        }
    }
}

public struct MenuSetupAttentionInput: Equatable, Sendable {
    public let hasUpdateResult: Bool
    public let closedLidNeedsAttention: Bool
    public let connectedAgentCount: Int

    public init(
        hasUpdateResult: Bool,
        closedLidNeedsAttention: Bool,
        connectedAgentCount: Int
    ) {
        self.hasUpdateResult = hasUpdateResult
        self.closedLidNeedsAttention = closedLidNeedsAttention
        self.connectedAgentCount = connectedAgentCount
    }
}

public struct MenuSetupAttentionPresentation: Equatable, Sendable {
    public let title: String
    public let detail: String

    public init(title: String, detail: String) {
        self.title = title
        self.detail = detail
    }
}

public enum MenuSetupAttentionPolicy {
    public static func presentation(
        for input: MenuSetupAttentionInput
    ) -> MenuSetupAttentionPresentation? {
        if input.hasUpdateResult {
            return MenuSetupAttentionPresentation(
                title: "Review update result",
                detail: "Open Settings to see what changed"
            )
        }
        if input.closedLidNeedsAttention {
            return MenuSetupAttentionPresentation(
                title: "Finish closed-lid setup",
                detail: "Complete the remaining step in Settings"
            )
        }
        if input.connectedAgentCount == 0 {
            return MenuSetupAttentionPresentation(
                title: "Connect an agent",
                detail: "Open Settings to connect your coding agent."
            )
        }
        return nil
    }
}
