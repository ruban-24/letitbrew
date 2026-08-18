public enum AgentConnectionState: String, Equatable, Sendable {
    case connecting = "Connecting"
    case connected = "Connected"
    case actionNeeded = "Action needed"
    case couldNotConnect = "Couldn’t connect"
}

/// Whether Let It Brew is managing an agent connection or the user has explicitly
/// disconnected it. This is state, not presentation copy: UI behavior must not
/// depend on matching a localized detail string.
public enum AgentConnectionDisposition: Equatable, Sendable {
    case managed
    case intentionallyDisconnected
    case disconnectFailed
}

public enum AgentSetupAttentionPolicy {
    public static func needsAttention(
        state: AgentConnectionState,
        disposition: AgentConnectionDisposition
    ) -> Bool {
        guard disposition != .intentionallyDisconnected else { return false }
        return state == .actionNeeded || state == .couldNotConnect
    }
}

public enum AgentHookConfigurationState: Equatable, Sendable {
    case healthy
    case needsConnection
    case invalid
}

/// Combines the two independent gates for a working integration: Let It Brew's
/// definitions must be healthy on disk, and Codex must say those exact
/// definitions are enabled and trusted at runtime.
public enum AgentConnectionPolicy {
    public static func state(
        configuration: AgentHookConfigurationState,
        codexTrust: CodexHookTrustResult?
    ) -> AgentConnectionState {
        switch configuration {
        case .needsConnection:
            return .connecting
        case .invalid:
            return .actionNeeded
        case .healthy:
            guard let codexTrust else { return .connected }
            switch codexTrust {
            case .trusted:
                return .connected
            case .approvalRequired:
                return .actionNeeded
            case .couldNotVerify:
                return .couldNotConnect
            }
        }
    }
}

public struct AgentConnectionMessageInput: Equatable, Sendable {
    public let name: String
    public let state: AgentConnectionState
    public let disposition: AgentConnectionDisposition

    public init(
        name: String,
        state: AgentConnectionState,
        disposition: AgentConnectionDisposition
    ) {
        self.name = name
        self.state = state
        self.disposition = disposition
    }
}

public enum AgentConnectionMessagePolicy {
    public static func displayedMessage(
        operationMessage: String?,
        connections: [AgentConnectionMessageInput]
    ) -> String? {
        guard let operationMessage else {
            return connections.contains {
                $0.disposition == .intentionallyDisconnected
            } ? "Disconnected agents are hidden and do not keep this Mac awake." : nil
        }
        guard operationMessage.hasPrefix("Connected ") else { return operationMessage }

        let attention = connections.filter {
            AgentSetupAttentionPolicy.needsAttention(
                state: $0.state,
                disposition: $0.disposition
            )
        }
        guard !attention.isEmpty else {
            return "Restart existing agent sessions to start tracking them."
        }

        let ready = connections.filter {
            $0.state == .connected && $0.disposition == .managed
        }
        if ready.count == 1, attention.count == 1,
           let readyName = ready.first?.name,
           let attentionName = attention.first?.name {
            return "\(readyName) is ready. Finish \(attentionName) setup before its sessions can appear."
        }
        if attention.count == 1, let attentionName = attention.first?.name {
            return "Finish \(attentionName) setup before its sessions can appear."
        }
        return "Finish the remaining connection steps before all agent sessions can appear."
    }
}
