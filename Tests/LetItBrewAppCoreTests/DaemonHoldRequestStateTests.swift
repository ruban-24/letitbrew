import Foundation
import Testing
@testable import LetItBrewAppCore

private let requestStart = Date(timeIntervalSince1970: 1_700_000_000)

@Test func replacingAConnectionClearsItsInFlightRequest() {
    var state = DaemonHoldRequestState()
    let oldRequest = state.beginRequest(desiredHold: true, at: requestStart)

    #expect(oldRequest != nil)
    #expect(state.isInFlight)

    state.replaceConnection()

    #expect(!state.isInFlight)
    let replacementRequest = state.beginRequest(desiredHold: false, at: requestStart)
    #expect(replacementRequest != nil)
}

@Test func lateCompletionFromReplacedConnectionCannotClearNewRequest() {
    var state = DaemonHoldRequestState()
    let oldRequest = state.beginRequest(desiredHold: true, at: requestStart)!
    state.replaceConnection()
    let newRequest = state.beginRequest(desiredHold: false, at: requestStart)!

    let acceptedOldCompletion = state.complete(oldRequest, succeeded: true)
    #expect(!acceptedOldCompletion)
    #expect(state.isInFlight)
    let acceptedNewCompletion = state.complete(newRequest, succeeded: true)
    #expect(acceptedNewCompletion)
    #expect(!state.isInFlight)
}

@Test func onlyOneRequestMayBeInFlightForAConnection() {
    var state = DaemonHoldRequestState()
    let request = state.beginRequest(desiredHold: true, at: requestStart)!

    let overlappingRequest = state.beginRequest(desiredHold: false, at: requestStart)
    #expect(overlappingRequest == nil)
    let acceptedCompletion = state.complete(request, succeeded: true)
    #expect(acceptedCompletion)
    let followingRequest = state.beginRequest(desiredHold: false, at: requestStart)
    #expect(followingRequest != nil)
}

@Test func failedFalseRequestCannotConfirmRelease() {
    var state = DaemonHoldRequestState()
    let acquire = state.beginRequest(desiredHold: true, at: requestStart)!
    let acquireCompleted = state.complete(acquire, succeeded: true)
    #expect(acquireCompleted)
    let release = state.beginRequest(desiredHold: false, at: requestStart)!

    let releaseCompleted = state.complete(release, succeeded: false)
    #expect(releaseCompleted)

    #expect(!state.isReleaseConfirmed)
    #expect(state.releaseConfirmationRequired)
    #expect(state.confirmedHold == nil)
}

@Test func timedOutFalseRequestBecomesRetryableAndUnconfirmed() {
    var state = DaemonHoldRequestState()
    let acquire = state.beginRequest(desiredHold: true, at: requestStart)!
    let acquireCompleted = state.complete(acquire, succeeded: true)
    #expect(acquireCompleted)
    _ = state.beginRequest(desiredHold: false, at: requestStart)

    let expired = state.expireRequestIfTimedOut(
        at: requestStart.addingTimeInterval(2),
        timeout: 1
    )

    #expect(expired)
    #expect(!state.isInFlight)
    #expect(!state.isReleaseConfirmed)
    #expect(state.releaseConfirmationRequired)
    let retry = state.beginRequest(
        desiredHold: false,
        at: requestStart.addingTimeInterval(2)
    )
    #expect(retry != nil)
}

@Test func lateCompletionAfterTimeoutCannotConfirmRelease() {
    var state = DaemonHoldRequestState()
    let acquire = state.beginRequest(desiredHold: true, at: requestStart)!
    let acquireCompleted = state.complete(acquire, succeeded: true)
    #expect(acquireCompleted)
    let timedOutRelease = state.beginRequest(desiredHold: false, at: requestStart)!
    let expired = state.expireRequestIfTimedOut(
        at: requestStart.addingTimeInterval(2),
        timeout: 1
    )
    #expect(expired)
    let replacementRelease = state.beginRequest(
        desiredHold: false,
        at: requestStart.addingTimeInterval(2)
    )!

    let acceptedTimedOutCompletion = state.complete(timedOutRelease, succeeded: true)
    #expect(!acceptedTimedOutCompletion)
    #expect(state.isInFlight)
    #expect(!state.isReleaseConfirmed)
    let replacementCompleted = state.complete(replacementRelease, succeeded: true)
    #expect(replacementCompleted)
    #expect(state.isReleaseConfirmed)
}

@Test func successfulFalseCompletionIsTheOnlyReleaseConfirmation() {
    var state = DaemonHoldRequestState()
    let acquire = state.beginRequest(desiredHold: true, at: requestStart)!

    let acquireCompleted = state.complete(acquire, succeeded: true)
    #expect(acquireCompleted)
    #expect(!state.isReleaseConfirmed)
    #expect(state.releaseConfirmationRequired)

    let release = state.beginRequest(desiredHold: false, at: requestStart)!
    let releaseCompleted = state.complete(release, succeeded: true)
    #expect(releaseCompleted)

    #expect(state.isReleaseConfirmed)
    #expect(!state.releaseConfirmationRequired)
    #expect(state.confirmedHold == false)
}

@Test func releaseRetryPreparationPreservesFreshFalseRequestUntilTimeout() {
    var state = DaemonHoldRequestState()
    let acquire = state.beginRequest(desiredHold: true, at: requestStart)!
    let acquireCompleted = state.complete(acquire, succeeded: true)
    #expect(acquireCompleted)
    let release = state.beginRequest(desiredHold: false, at: requestStart)!

    let replaceFreshConnection = state.prepareReleaseRetry(
        at: requestStart.addingTimeInterval(1),
        timeout: 2
    )

    #expect(!replaceFreshConnection)
    #expect(state.isInFlight)

    let replaceTimedOutConnection = state.prepareReleaseRetry(
        at: requestStart.addingTimeInterval(2),
        timeout: 2
    )

    #expect(replaceTimedOutConnection)
    #expect(!state.isInFlight)
    #expect(state.releaseConfirmationRequired)
    #expect(!state.isReleaseConfirmed)
    let acceptedLateCompletion = state.complete(release, succeeded: true)
    #expect(!acceptedLateCompletion)
}

@Test func failedReleaseRetryPreparationRequestsConnectionReplacement() {
    var state = DaemonHoldRequestState()
    let release = state.beginRequest(desiredHold: false, at: requestStart)!
    let releaseCompleted = state.complete(release, succeeded: false)
    #expect(releaseCompleted)

    let replaceConnection = state.prepareReleaseRetry(
        at: requestStart.addingTimeInterval(1),
        timeout: 2
    )

    #expect(replaceConnection)
    #expect(!state.isInFlight)
    #expect(state.releaseConfirmationRequired)
    #expect(!state.isReleaseConfirmed)
}
