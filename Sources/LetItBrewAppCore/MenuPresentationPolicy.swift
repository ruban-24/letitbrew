import Foundation
import LetItBrewCore

public enum MenuSessionState: Sendable {
    case working
    case idle
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

public struct SessionMenuInput: Sendable {
    public let id: String
    public let tool: String
    public let project: String
    public let repositoryPath: String
    public let state: MenuSessionState
    public let activeWorkingTime: TimeInterval
    public let updatedAt: Date

    public init(
        id: String,
        tool: String,
        project: String,
        repositoryPath: String,
        state: MenuSessionState,
        activeWorkingTime: TimeInterval,
        updatedAt: Date
    ) {
        self.id = id
        self.tool = tool
        self.project = project
        self.repositoryPath = repositoryPath
        self.state = state
        self.activeWorkingTime = activeWorkingTime
        self.updatedAt = updatedAt
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

    public var accessibilityState: String {
        "Working"
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
    public static func rows(
        from inputs: [SessionMenuInput],
        now _: Date
    ) -> [MenuSessionPresentation] {
        inputs
            .filter { $0.state == .working }
            .map { input in
                MenuSessionPresentation(
                id: input.id,
                toolID: input.tool.lowercased(),
                toolName: displayTool(input.tool),
                project: input.project.isEmpty ? "Unknown project" : input.project,
                repositoryID: input.repositoryPath,
                stateText: "Working",
                activeTimeText: duration(input.activeWorkingTime) + " active",
                updatedAt: input.updatedAt
            )
            }
            .sorted {
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
    public static func groups(
        from rows: [MenuSessionPresentation]
    ) -> [MenuRepositoryPresentation] {
        Dictionary(grouping: rows, by: \.repositoryID)
            .map { repositoryID, sessions in
                let sortedSessions = sessions.sorted(by: sessionOrder)
                let shortIDs = uniqueShortIDs(for: sortedSessions.map(\.id))
                return MenuRepositoryPresentation(
                    id: repositoryID,
                    project: sortedSessions.first?.project ?? "Unknown project",
                    summaryText: summary(for: sortedSessions),
                    sessionCountText: sortedSessions.count == 1
                        ? "1 working"
                        : "\(sortedSessions.count) working",
                    sessions: sortedSessions.map {
                        MenuRepositorySessionPresentation(
                            session: $0,
                            shortID: shortIDs[$0.id] ?? $0.id
                        )
                    }
                )
            }
            .sorted(by: groupOrder)
    }

    private static func sessionOrder(
        _ lhs: MenuSessionPresentation,
        _ rhs: MenuSessionPresentation
    ) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
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
        guard group.sessions.count > 1 else {
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
              groups.contains(where: { $0.id == current && $0.sessions.count > 1 })
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
            case .battery(let percent):
                "Battery at \(percent)% — your Mac can sleep"
            case .connectedPowerOnly:
                "Battery power released the sleep hold"
            case .lowPowerMode:
                "Low Power Mode released the sleep hold"
            case .thermal:
                "Mac is too warm — it can sleep"
            case .powerUnavailable:
                "Power status unavailable — your Mac can sleep"
            }
        }
    }

    public static func resolve(
        isPaused: Bool,
        isKeepingAwake: Bool,
        releaseConstraint: ReleaseConstraint? = nil
    ) -> String {
        if isPaused { return "Let It Brew is paused" }
        if isKeepingAwake { return "Keeping your Mac awake" }
        if let releaseConstraint { return releaseConstraint.message }
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
