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

/// Classifies one descriptor-captured target for the app's exact preparation
/// handoff. Absence must be decided before adapter ownership validation:
/// OpenCode correctly refuses to remove a missing whole-file plugin, while a
/// missing plugin is nevertheless the valid first-connect state.
public enum AgentExactDiskInspection {
    public struct Result: Equatable, Sendable {
        public let snapshot: ExactFileSnapshot
        public let inspection: AgentExactPreparation.Inspection
        public let report: HookInstallReport?

        public init(
            snapshot: ExactFileSnapshot,
            inspection: AgentExactPreparation.Inspection,
            report: HookInstallReport?
        ) {
            self.snapshot = snapshot
            self.inspection = inspection
            self.report = report
        }
    }

    public static func inspect(
        agent: AgentID,
        snapshot: ExactFileSnapshot,
        data: Data?,
        helperPath: String
    ) -> Result {
        guard snapshot.exists == (data != nil) else {
            return Result(snapshot: snapshot, inspection: .invalid, report: nil)
        }
        guard let data else {
            return Result(snapshot: snapshot, inspection: .absent, report: nil)
        }
        do {
            let report = try AgentDiskInspection.report(
                agent: agent,
                data: data,
                helperPath: helperPath
            )
            let inspection: AgentExactPreparation.Inspection = report.isAbsent
                ? .absent : report.isHealthy ? .healthyOwned : .repairableOwned
            return Result(snapshot: snapshot, inspection: inspection, report: report)
        } catch {
            return Result(snapshot: snapshot, inspection: .invalid, report: nil)
        }
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
        readExactTarget: (URL, Bool) -> AgentExactTargetRead
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
        switch readExactTarget(target, usedRecordedTarget) {
        case .absent(let snapshot):
            return .init(target: URL(fileURLWithPath: snapshot.path), snapshot: snapshot, state: .absent,
                         diagnostic: "No Let It Brew connection is installed.",
                         usedRecordedTarget: usedRecordedTarget)
        case .invalid(let resolvedURL, let reason):
            return .init(target: resolvedURL, snapshot: nil, state: .invalid,
                         diagnostic: reason, usedRecordedTarget: usedRecordedTarget)
        case .regular(let snapshot, let data):
            let resolvedTarget = URL(fileURLWithPath: snapshot.path)
            do {
                let report = try report(agent: agent, data: data, helperPath: helperPath)
                let state: AgentConfigurationInspectionState = report.isAbsent
                    ? .absent : report.isHealthy ? .healthyOwned : .repairableOwned
                return .init(target: resolvedTarget, snapshot: snapshot, state: state,
                             diagnostic: details(report), usedRecordedTarget: usedRecordedTarget)
            } catch {
                return .init(target: resolvedTarget, snapshot: snapshot, state: .invalid,
                             diagnostic: "Let It Brew will not change this unreadable or unowned configuration: \(error)",
                             usedRecordedTarget: usedRecordedTarget)
            }
        }
    }

    fileprivate static func report(agent: AgentID, data: Data, helperPath: String) throws -> HookInstallReport {
        switch agent {
        case .claude:
            _ = try ClaudeHooks.install(into: data, cliPath: helperPath)
            return ClaudeHooks.report(for: data, cliPath: helperPath)
        case .codex:
            _ = try CodexHooks.install(into: data, cliPath: helperPath)
            return CodexHooks.report(for: data, cliPath: helperPath)
        case .opencode:
            _ = try OpenCodePlugin.install(into: data, cliPath: helperPath)
            return OpenCodePlugin.report(for: data, cliPath: helperPath)
        case .copilot:
            _ = try CopilotHooks.install(into: data, cliPath: helperPath)
            return CopilotHooks.report(for: data, cliPath: helperPath)
        }
    }

    private static func details(_ report: HookInstallReport) -> String {
        if report.isHealthy { return "Let It Brew’s connection is healthy." }
        if report.isAbsent { return "No Let It Brew connection is installed." }
        return "Let It Brew’s connection needs repair."
    }
}
