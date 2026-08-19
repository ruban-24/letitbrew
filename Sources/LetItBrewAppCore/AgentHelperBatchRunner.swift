import Foundation

public struct AgentHelperOperationResult: Equatable, Sendable {
    public let agentID: String
    public let status: Int32
    public let output: String
    public let timedOut: Bool

    public init(agentID: String, status: Int32, output: String, timedOut: Bool) {
        self.agentID = agentID
        self.status = status
        self.output = output
        self.timedOut = timedOut
    }

    public var succeeded: Bool { !timedOut && status == 0 }
}

/// Runs the helper once per agent so a failed or hung mutation has an
/// independent result and cannot suppress attempts for the remaining agents.
public enum AgentHelperBatchRunner {
    public static func run(
        executableURL: URL,
        command: String,
        agentIDs: [String],
        timeout: TimeInterval,
        terminationGrace: TimeInterval = 0.25
    ) -> [AgentHelperOperationResult] {
        agentIDs.map { agentID in
            let result = BoundedProcessRunner.run(
                executableURL: executableURL,
                arguments: [command, agentID],
                timeout: timeout,
                terminationGrace: terminationGrace
            )
            let launchError = result.launchError.map { "\($0)\n" } ?? ""
            return AgentHelperOperationResult(
                agentID: agentID,
                status: result.status,
                output: launchError + String(decoding: result.output, as: UTF8.self),
                timedOut: result.timedOut
            )
        }
    }
}

/// The only allowed follow-ups after an explicit disconnect attempt. In
/// particular there is deliberately no reconnect/repair case: a helper that
/// removes hooks and then fails or times out must not have that removal
/// silently reversed by the ordinary automatic-connection path.
public enum AgentDisconnectFollowUp: Equatable, Sendable {
    case markDisconnected(agentID: String)
    case showFailure(AgentHelperOperationResult)
}

public enum AgentDisconnectCompletionPolicy {
    public static func followUps(
        for results: [AgentHelperOperationResult]
    ) -> [AgentDisconnectFollowUp] {
        results.map { result in
            result.succeeded
                ? .markDisconnected(agentID: result.agentID)
                : .showFailure(result)
        }
    }
}
