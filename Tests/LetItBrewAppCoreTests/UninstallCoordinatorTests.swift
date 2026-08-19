import Testing
@testable import LetItBrewAppCore

/// Records every call so a test can assert that a refused precheck performed
/// no removal at all, not merely that it reported failure.
final class RecordingUninstallEnvironment: UninstallEnvironment, @unchecked Sendable {
    var calls: [UninstallStep] = []
    var failures: [UninstallStep: UninstallFailure] = [:]
    var reconciliation: UninstallDaemonReconciliation = .present
    /// Steps that fail only on their first call, to model a transient daemon.
    var failuresClearedAfterFirstCall: Set<UninstallStep> = []
    /// Runs after recording a call and before returning its result, so a test
    /// can interleave a second coordinator call (e.g. `cancel()`) mid-teardown
    /// — see `cancelDuringTeardownDoesNotInterruptIt`.
    var onCall: ((UninstallStep) async -> Void)?

    private func perform(_ step: UninstallStep) async -> Result<Void, UninstallFailure> {
        calls.append(step)
        await onCall?(step)
        guard let failure = failures[step] else { return .success(()) }
        if failuresClearedAfterFirstCall.contains(step) {
            failures[step] = nil
        }
        return .failure(failure)
    }

    func releaseHolds() async -> Result<Void, UninstallFailure> { await perform(.releaseHolds) }
    func reconcileDaemon() async -> Result<UninstallDaemonReconciliation, UninstallFailure> {
        calls.append(.reconcileDaemon)
        await onCall?(.reconcileDaemon)
        guard let failure = failures[.reconcileDaemon] else {
            return .success(reconciliation)
        }
        if failuresClearedAfterFirstCall.contains(.reconcileDaemon) {
            failures[.reconcileDaemon] = nil
        }
        return .failure(failure)
    }
    func unregisterDaemon() async -> Result<Void, UninstallFailure> { await perform(.unregisterDaemon) }
    func removeClaudeHooks() async -> Result<Void, UninstallFailure> { await perform(.removeClaudeHooks) }
    func removeCodexHooks() async -> Result<Void, UninstallFailure> { await perform(.removeCodexHooks) }
    func removeOpenCodeHooks() async -> Result<Void, UninstallFailure> { await perform(.removeOpenCodeHooks) }
    func removeCopilotHooks() async -> Result<Void, UninstallFailure> { await perform(.removeCopilotHooks) }
    func disableLaunchAtLogin() async -> Result<Void, UninstallFailure> { await perform(.disableLaunchAtLogin) }
    func deleteUserData() async -> Result<Void, UninstallFailure> { await perform(.deleteUserData) }
    func clearPreferences() async -> Result<Void, UninstallFailure> { await perform(.clearPreferences) }
    func trashBundle() async -> Result<Void, UninstallFailure> { await perform(.trashBundle) }
}

func makeFailure(_ step: UninstallStep) -> UninstallFailure {
    UninstallFailure(
        step: step,
        message: "Let It Brew could not complete \(step.rawValue).",
        diagnostic: "diagnostic for \(step.rawValue)"
    )
}

@Test @MainActor func aCleanPrecheckAsksForConfirmationWithoutRemovingAnything() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()

    #expect(coordinator.state == .awaitingConfirmation)
    #expect(environment.calls == [.releaseHolds, .reconcileDaemon])
}

@Test @MainActor func aTransientReconciliationFailureIsRetriedExactlyOnceAndSucceeds() async {
    let environment = RecordingUninstallEnvironment()
    environment.failures[.reconcileDaemon] = makeFailure(.reconcileDaemon)
    environment.failuresClearedAfterFirstCall = [.reconcileDaemon]
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()

    #expect(coordinator.state == .awaitingConfirmation)
    #expect(environment.calls == [
        .releaseHolds, .reconcileDaemon,
        .releaseHolds, .reconcileDaemon,
    ])
}

@Test @MainActor func aPersistentGateFailureBlocksWithoutRemovingAnything() async {
    let environment = RecordingUninstallEnvironment()
    environment.failures[.reconcileDaemon] = makeFailure(.reconcileDaemon)
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()

    #expect(coordinator.state == .blocked(makeFailure(.reconcileDaemon), offersDiagnostic: false))
    let removalSteps: Set<UninstallStep> = [
        .unregisterDaemon, .removeClaudeHooks, .removeCodexHooks,
        .removeOpenCodeHooks, .removeCopilotHooks,
        .disableLaunchAtLogin, .deleteUserData, .clearPreferences, .trashBundle,
    ]
    #expect(environment.calls.allSatisfy { !removalSteps.contains($0) })
}

@Test @MainActor func aSecondUserRetryOffersTheDiagnostic() async {
    let environment = RecordingUninstallEnvironment()
    environment.failures[.unregisterDaemon] = makeFailure(.unregisterDaemon)
    environment.failures[.reconcileDaemon] = makeFailure(.reconcileDaemon)
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    #expect(coordinator.state == .blocked(makeFailure(.reconcileDaemon), offersDiagnostic: false))

    await coordinator.retryPrecheck()
    #expect(coordinator.state == .blocked(makeFailure(.reconcileDaemon), offersDiagnostic: true))
}

@Test @MainActor func cancellingFromBlockedReturnsToIdle() async {
    let environment = RecordingUninstallEnvironment()
    environment.failures[.releaseHolds] = makeFailure(.releaseHolds)
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    coordinator.cancel()

    #expect(coordinator.state == .idle)
}

@Test @MainActor func aCleanTeardownRunsGatesFirstThenEveryRemovalInOrder() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.calls.removeAll()
    await coordinator.confirm()

    #expect(coordinator.state == .finished)
    #expect(environment.calls == [
        .releaseHolds,
        .reconcileDaemon,
        .unregisterDaemon,
        .removeClaudeHooks,
        .removeCodexHooks,
        .removeOpenCodeHooks,
        .removeCopilotHooks,
        .disableLaunchAtLogin,
        .deleteUserData,
        .clearPreferences,
        .trashBundle,
    ])
}

@Test @MainActor func anAffirmativelyAbsentDaemonSkipsUnregisterAndCompletesCleanup() async {
    let environment = RecordingUninstallEnvironment()
    environment.reconciliation = .affirmativelyAbsent
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.calls.removeAll()
    await coordinator.confirm()

    #expect(coordinator.state == .finished)
    #expect(environment.calls == [
        .releaseHolds,
        .reconcileDaemon,
        .removeClaudeHooks,
        .removeCodexHooks,
        .removeOpenCodeHooks,
        .removeCopilotHooks,
        .disableLaunchAtLogin,
        .deleteUserData,
        .clearPreferences,
        .trashBundle,
    ])
}

@Test @MainActor func aFailedUnregisterGateRunsNoRemovalAndBlocks() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.failures[.unregisterDaemon] = makeFailure(.unregisterDaemon)
    environment.calls.removeAll()
    await coordinator.confirm()

    #expect(coordinator.state == .blocked(makeFailure(.unregisterDaemon), offersDiagnostic: true))
    #expect(environment.calls == [.releaseHolds, .reconcileDaemon, .unregisterDaemon])
}

// MARK: - Critical C: confirm() reruns every hard gate, not just two of them

@Test @MainActor func aFailedReconcileGateDuringConfirmRunsNoRemovalAndBlocks() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.failures[.reconcileDaemon] = makeFailure(.reconcileDaemon)
    environment.calls.removeAll()
    await coordinator.confirm()

    #expect(coordinator.state == .blocked(makeFailure(.reconcileDaemon), offersDiagnostic: true))
    #expect(environment.calls == [.releaseHolds, .reconcileDaemon])
}

@Test @MainActor func aFailedReleaseHoldsGateDuringConfirmRunsNoRemovalAndBlocks() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.failures[.releaseHolds] = makeFailure(.releaseHolds)
    environment.calls.removeAll()
    await coordinator.confirm()

    #expect(coordinator.state == .blocked(makeFailure(.releaseHolds), offersDiagnostic: true))
    #expect(environment.calls == [.releaseHolds])
}

// MARK: - Important E: cancel cannot interleave into an already-started teardown

@Test @MainActor func cancelDuringTeardownDoesNotInterruptIt() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.calls.removeAll()
    environment.onCall = { step in
        guard step == .removeClaudeHooks else { return }
        coordinator.cancel()
        // Guarded: a Cancel tap that lands after teardown has actually
        // started must not be able to reset state out from under it.
        #expect(coordinator.state == .awaitingConfirmation)
    }

    await coordinator.confirm()

    #expect(coordinator.state == .finished)
    #expect(environment.calls == [
        .releaseHolds,
        .reconcileDaemon,
        .unregisterDaemon,
        .removeClaudeHooks,
        .removeCodexHooks,
        .removeOpenCodeHooks,
        .removeCopilotHooks,
        .disableLaunchAtLogin,
        .deleteUserData,
        .clearPreferences,
        .trashBundle,
    ])
}

@Test @MainActor func aFailedHookRemovalRetainsRecoveryDataAndBundleForRetry() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.failures[.removeCodexHooks] = makeFailure(.removeCodexHooks)
    environment.calls.removeAll()
    await coordinator.confirm()

    guard case .report(let leftovers) = coordinator.state else {
        Issue.record("Expected a report state.")
        return
    }
    #expect(leftovers.map(\.step) == [.removeCodexHooks, .trashBundle])
    #expect(environment.calls.contains(.removeOpenCodeHooks))
    #expect(environment.calls.contains(.removeCopilotHooks))
    #expect(!environment.calls.contains(.disableLaunchAtLogin))
    #expect(!environment.calls.contains(.deleteUserData))
    #expect(!environment.calls.contains(.clearPreferences))
    #expect(!environment.calls.contains(.trashBundle))
}

@Test @MainActor func aFailedTrashStillFinishesAndIsReported() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.failures[.trashBundle] = makeFailure(.trashBundle)
    await coordinator.confirm()

    #expect(coordinator.state == .report(leftovers: [makeFailure(.trashBundle)]))
    coordinator.acknowledgeReport()
    #expect(coordinator.state == .finished)
}

@Test @MainActor func theReportNeverListsAStepThatSucceeded() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.beginPrecheck()
    environment.failures[.deleteUserData] = makeFailure(.deleteUserData)
    await coordinator.confirm()

    guard case .report(let leftovers) = coordinator.state else {
        Issue.record("Expected a report state.")
        return
    }
    #expect(leftovers.map(\.step) == [.deleteUserData])
}

@Test @MainActor func confirmingIsIgnoredUnlessThePrecheckAskedForIt() async {
    let environment = RecordingUninstallEnvironment()
    let coordinator = UninstallCoordinator(environment: environment)

    await coordinator.confirm()

    #expect(coordinator.state == .idle)
    #expect(environment.calls.isEmpty)
}
