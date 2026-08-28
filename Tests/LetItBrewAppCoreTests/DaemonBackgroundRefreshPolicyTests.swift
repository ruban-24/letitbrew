import Testing
@testable import LetItBrewAppCore

@Test func backgroundRefreshDoesNothingWhileDaemonWorkIsInFlight() {
    let blockedStates = [
        (recovery: true, handshake: false, holdRequest: false),
        (recovery: false, handshake: true, holdRequest: false),
        (recovery: false, handshake: false, holdRequest: true),
    ]

    for state in blockedStates {
        #expect(DaemonBackgroundRefreshPolicy.action(
            recoveryInFlight: state.recovery,
            handshakeInFlight: state.handshake,
            holdRequestInFlight: state.holdRequest,
            daemonAvailable: true
        ) == .none)
    }
}

@Test func backgroundRefreshSynchronizesAHealthyDaemonWithoutRecovery() {
    #expect(DaemonBackgroundRefreshPolicy.action(
        recoveryInFlight: false,
        handshakeInFlight: false,
        holdRequestInFlight: false,
        daemonAvailable: true
    ) == .synchronizeHold)
}

@Test func backgroundRefreshRecoversOnlyWhenTheDaemonIsUnavailable() {
    #expect(DaemonBackgroundRefreshPolicy.action(
        recoveryInFlight: false,
        handshakeInFlight: false,
        holdRequestInFlight: false,
        daemonAvailable: false
    ) == .recover)
}
