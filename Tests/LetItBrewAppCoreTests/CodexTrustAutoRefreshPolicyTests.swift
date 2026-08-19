import Testing
@testable import LetItBrewAppCore

@Test(arguments: [
    AgentConnectionState.actionNeeded,
    AgentConnectionState.couldNotConnect,
])
func managedCodexAttentionStatesRefreshAutomatically(state: AgentConnectionState) {
    #expect(CodexTrustAutoRefreshPolicy.shouldRefresh(
        state: state,
        disposition: .managed,
        isCodexSelected: true
    ))
}

@Test(arguments: [
    AgentConnectionState.connecting,
    AgentConnectionState.connected,
])
func settledManagedCodexStatesDoNotRefreshAutomatically(state: AgentConnectionState) {
    #expect(!CodexTrustAutoRefreshPolicy.shouldRefresh(
        state: state,
        disposition: .managed,
        isCodexSelected: true
    ))
}

@Test func nonManagedCodexConnectionsNeverRefreshAutomatically() {
    let states: [AgentConnectionState] = [
        .connecting, .connected, .actionNeeded, .couldNotConnect,
    ]
    let dispositions: [AgentConnectionDisposition] = [
        .intentionallyDisconnected, .disconnectFailed,
    ]
    for state in states {
        for disposition in dispositions {
            #expect(!CodexTrustAutoRefreshPolicy.shouldRefresh(
                state: state,
                disposition: disposition,
                isCodexSelected: true
            ))
        }
    }
}

@Test func unselectedCodexNeverRefreshesOrReconnects() {
    #expect(!CodexTrustAutoRefreshPolicy.shouldRefresh(
        state: .actionNeeded,
        disposition: .managed,
        isCodexSelected: false
    ))
}
