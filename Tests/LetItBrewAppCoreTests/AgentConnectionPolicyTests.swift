import Testing
@testable import LetItBrewAppCore

@Test func claudeIsConnectedOnlyAfterItsConfigurationIsHealthy() {
    #expect(AgentConnectionPolicy.state(
        configuration: .healthy,
        codexTrust: nil
    ) == .connected)
    #expect(AgentConnectionPolicy.state(
        configuration: .needsConnection,
        codexTrust: nil
    ) == .connecting)
    #expect(AgentConnectionPolicy.state(
        configuration: .invalid,
        codexTrust: nil
    ) == .actionNeeded)
}

@Test func validButUntrustedCodexIsNeverConnected() {
    #expect(AgentConnectionPolicy.state(
        configuration: .healthy,
        codexTrust: .approvalRequired
    ) == .actionNeeded)
    #expect(AgentConnectionPolicy.state(
        configuration: .healthy,
        codexTrust: .couldNotVerify
    ) == .couldNotConnect)
    #expect(AgentConnectionPolicy.state(
        configuration: .healthy,
        codexTrust: .trusted
    ) == .connected)
}

@Test func configurationFailureWinsOverAStaleTrustReading() {
    #expect(AgentConnectionPolicy.state(
        configuration: .invalid,
        codexTrust: .trusted
    ) == .actionNeeded)
    #expect(AgentConnectionPolicy.state(
        configuration: .needsConnection,
        codexTrust: .trusted
    ) == .connecting)
}

@Test func intentionalDisconnectNeverRequestsSetupAttention() {
    for state in [AgentConnectionState.actionNeeded, .couldNotConnect] {
        #expect(AgentSetupAttentionPolicy.needsAttention(
            state: state,
            disposition: .managed
        ))
        #expect(!AgentSetupAttentionPolicy.needsAttention(
            state: state,
            disposition: .intentionallyDisconnected
        ))
        #expect(AgentSetupAttentionPolicy.needsAttention(
            state: state,
            disposition: .disconnectFailed
        ))
    }
}

@Test func connectionSuccessMessageNeverContradictsAnAgentThatStillNeedsSetup() {
    let connections = [
        AgentConnectionMessageInput(
            name: "Claude Code",
            state: .connected,
            disposition: .managed
        ),
        AgentConnectionMessageInput(
            name: "Codex",
            state: .actionNeeded,
            disposition: .managed
        ),
    ]

    #expect(AgentConnectionMessagePolicy.displayedMessage(
        operationMessage: "Connected Claude Code and Codex. Restart agent sessions that were already open.",
        connections: connections
    ) == "Claude Code is ready. Finish Codex setup before its sessions can appear.")

    #expect(AgentConnectionMessagePolicy.displayedMessage(
        operationMessage: "Disconnected Codex.",
        connections: connections
    ) == "Disconnected Codex.")
}

@Test func disconnectedAgentsProduceOneSharedNotice() {
    let connections = ["Claude Code", "Codex", "OpenCode", "GitHub Copilot CLI"].map {
        AgentConnectionMessageInput(
            name: $0,
            state: .actionNeeded,
            disposition: .intentionallyDisconnected
        )
    }

    #expect(AgentConnectionMessagePolicy.displayedMessage(
        operationMessage: nil,
        connections: connections
    ) == "Disconnected agents are hidden and do not keep this Mac awake.")
}

@Test func successfulConnectionUsesOneSharedRestartNotice() {
    let connections = ["Claude Code", "Codex", "OpenCode", "GitHub Copilot CLI"].map {
        AgentConnectionMessageInput(
            name: $0,
            state: .connected,
            disposition: .managed
        )
    }

    #expect(AgentConnectionMessagePolicy.displayedMessage(
        operationMessage: "Connected Claude Code and Codex. Restart agent sessions that were already open.",
        connections: connections
    ) == "Restart existing agent sessions to start tracking them.")
}
