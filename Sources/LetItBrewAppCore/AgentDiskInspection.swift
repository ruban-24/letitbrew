import Foundation
import LetItBrewCore

/// The registry is decoded before this boundary is entered.  A malformed
/// registry is deliberately terminal: guessing another configuration root
/// would make an inspection capable of changing the wrong user file later.
public enum AgentDiskRegistry: Equatable, Sendable {
    case valid(AgentInstallRegistry?)
    case invalid(String)
}

/// One exact, already-resolved target read.  The live reader owns symlink
/// policy; this component consumes only that single answer and never probes a
/// second location.
public enum AgentExactTargetRead: Equatable, Sendable {
    case absent(ExactFileSnapshot)
    case regular(ExactFileSnapshot, Data)
    case invalid(resolvedURL: URL, reason: String)
}

public struct AgentDiskInspectionResult: Equatable, Sendable {
    public let target: URL?
    public let snapshot: ExactFileSnapshot?
    public let state: AgentConfigurationInspectionState
    public let diagnostic: String
    public let usedRecordedTarget: Bool

    public init(target: URL?, snapshot: ExactFileSnapshot?, state: AgentConfigurationInspectionState, diagnostic: String, usedRecordedTarget: Bool) {
        self.target = target
        self.snapshot = snapshot
        self.state = state
        self.diagnostic = diagnostic
        self.usedRecordedTarget = usedRecordedTarget
    }

    public var launchInspection: AgentConnectionInspection {
        .init(
            agentID: "",
            state: state,
            hasRecordedTarget: usedRecordedTarget,
            exactTargetSnapshot: snapshot
        )
    }
}

/// Pure, one-target configuration classification used by the app model.  It
/// does not launch a vendor process, enumerate a directory, or write bytes.
public enum AgentDiskInspection {
    public static func inspect(
        agent: AgentID,
        registry: AgentDiskRegistry,
        defaultTarget: URL,
        helperPath: String,
        readExactTarget: (URL) -> AgentExactTargetRead
    ) -> AgentDiskInspectionResult {
        let recorded: String?
        switch registry {
        case .invalid(let message):
            return .init(target: nil, snapshot: nil, state: .invalid,
                         diagnostic: "Let It Brew could not safely read its recorded agent target: \(message)",
                         usedRecordedTarget: false)
        case .valid(let value):
            recorded = value?.targets[agent]
        }

        let target = recorded.map(URL.init(fileURLWithPath:)) ?? defaultTarget
        let usedRecordedTarget = recorded != nil
        switch readExactTarget(target) {
        case .absent(let snapshot):
            return .init(target: target, snapshot: snapshot, state: .absent,
                         diagnostic: "No Let It Brew connection is installed.",
                         usedRecordedTarget: usedRecordedTarget)
        case .invalid(let resolvedURL, let reason):
            return .init(target: resolvedURL, snapshot: nil, state: .invalid,
                         diagnostic: reason, usedRecordedTarget: usedRecordedTarget)
        case .regular(let snapshot, let data):
            do {
                let report = try report(agent: agent, data: data, helperPath: helperPath)
                let state: AgentConfigurationInspectionState = report.isAbsent
                    ? .absent : report.isHealthy ? .healthyOwned : .repairableOwned
                return .init(target: target, snapshot: snapshot, state: state,
                             diagnostic: details(report), usedRecordedTarget: usedRecordedTarget)
            } catch {
                return .init(target: target, snapshot: snapshot, state: .invalid,
                             diagnostic: "Let It Brew will not change this unreadable or unowned configuration: \(error)",
                             usedRecordedTarget: usedRecordedTarget)
            }
        }
    }

    private static func report(agent: AgentID, data: Data, helperPath: String) throws -> HookInstallReport {
        switch agent {
        case .claude:
            _ = try ClaudeHooks.remove(from: data)
            return ClaudeHooks.report(for: data, cliPath: helperPath)
        case .codex:
            _ = try CodexHooks.remove(from: data)
            return CodexHooks.report(for: data, cliPath: helperPath)
        case .cursor:
            _ = try CursorHooks.remove(from: data)
            return CursorHooks.report(for: data, cliPath: helperPath)
        case .opencode:
            _ = try OpenCodePlugin.remove(from: data)
            return OpenCodePlugin.report(for: data, cliPath: helperPath)
        case .copilot:
            _ = try CopilotHooks.remove(from: data)
            return CopilotHooks.report(for: data, cliPath: helperPath)
        }
    }

    private static func details(_ report: HookInstallReport) -> String {
        if report.isHealthy { return "Let It Brew’s connection is healthy." }
        if report.isAbsent { return "No Let It Brew connection is installed." }
        return "Let It Brew’s connection needs repair."
    }
}
