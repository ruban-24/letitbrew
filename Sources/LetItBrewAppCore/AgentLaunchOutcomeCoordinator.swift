import LetItBrewCore

public enum AgentLaunchHelperOutcome: Equatable, Sendable {
    case notRun
    case succeeded(changedVendorBytes: Bool)
    case failed(String)
}

public struct AgentLaunchRowPresentation: Equatable, Sendable {
    public let agentID: String
    public let state: AgentConnectionState
    public let details: [String]
    public let disposition: AgentConnectionDisposition
}

/// Executes only immutable preparations handed to it and presents their
/// outcomes against the original inspections.  It has no URL/environment
/// input, so an exact refusal cannot become a fallback capture or mutation.
public enum AgentLaunchOutcomeCoordinator {
    public static func execute(
        _ preparations: [AgentLaunchPreparation],
        runRecorded: (String) -> AgentLaunchHelperOutcome,
        runExact: (ExactTargetPreparation) -> AgentLaunchHelperOutcome
    ) -> [String: AgentLaunchHelperOutcome] {
        var outcomes: [String: AgentLaunchHelperOutcome] = [:]
        AgentLaunchPreparationRunner.run(
            preparations,
            runRecorded: { id in outcomes[id] = runRecorded(id) },
            runExact: { request in outcomes[request.agent.rawValue] = runExact(request) }
        )
        return outcomes
    }

    public static func present(
        inspections: [AgentConnectionInspection],
        selectedAgentIDs: Set<String>,
        outcomes: [String: AgentLaunchHelperOutcome],
        codexTrust: CodexHookTrustResult? = nil
    ) -> [AgentLaunchRowPresentation] {
        let byID = Dictionary(uniqueKeysWithValues: inspections.map { ($0.agentID, $0) })
        return AgentID.allCases.map { agent in
            let id = agent.rawValue
            guard selectedAgentIDs.contains(id) else {
                return .init(agentID: id, state: .actionNeeded,
                             details: ["Disconnected. Choose Connect to use this agent with Let It Brew."],
                             disposition: .intentionallyDisconnected)
            }
            guard let inspection = byID[id] else {
                return .init(agentID: id, state: .actionNeeded,
                             details: ["Let It Brew could not inspect this selected connection."], disposition: .managed)
            }
            switch inspection.state {
            case .invalid:
                return .init(agentID: id, state: .actionNeeded,
                             details: ["Let It Brew will not change this invalid connection. Fix it, then choose Check Again."], disposition: .managed)
            case .healthyOwned where outcomes[id] == nil:
                let state: AgentConnectionState
                if agent == .codex {
                    guard let codexTrust else {
                        return .init(agentID: id, state: .couldNotConnect,
                                     details: ["Let It Brew could not verify Codex hook approval."], disposition: .managed)
                    }
                    state = AgentConnectionPolicy.state(configuration: .healthy, codexTrust: codexTrust)
                } else { state = .connected }
                return .init(agentID: id, state: state, details: details(for: state), disposition: .managed)
            default:
                switch outcomes[id] ?? .failed("Let It Brew did not receive a preparation result.") {
                case .succeeded(let changed):
                    let state: AgentConnectionState
                    if agent == .codex {
                        guard let codexTrust else {
                            return .init(agentID: id, state: .couldNotConnect,
                                         details: ["Let It Brew could not verify Codex hook approval."], disposition: .managed)
                        }
                        state = AgentConnectionPolicy.state(configuration: .healthy, codexTrust: codexTrust)
                    } else { state = .connected }
                    return .init(agentID: id, state: state,
                                 details: state == .connected && changed ? ["Restart sessions that were already open."] : details(for: state), disposition: .managed)
                case .failed(let message):
                    return .init(agentID: id, state: .actionNeeded,
                                 details: [message], disposition: .managed)
                case .notRun:
                    return .init(agentID: id, state: .actionNeeded,
                                 details: ["Let It Brew did not prepare this selected connection."], disposition: .managed)
                }
            }
        }
    }

    private static func details(for state: AgentConnectionState) -> [String] {
        switch state {
        case .connected, .connecting: []
        case .actionNeeded: ["Approve Let It Brew in Codex, then try again."]
        case .couldNotConnect: ["Let It Brew could not verify Codex hook approval."]
        }
    }
}
