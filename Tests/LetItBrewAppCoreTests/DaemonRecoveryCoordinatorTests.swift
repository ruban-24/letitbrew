import Foundation
import Testing
@testable import LetItBrewAppCore

private let oldIdentity = DaemonRecoveryIdentity(
    protocolVersion: 1,
    appBuild: "app-old",
    daemonBuild: "daemon-old"
)

private let expectedIdentity = DaemonRecoveryIdentity(
    protocolVersion: 1,
    appBuild: "app-new",
    daemonBuild: "daemon-new"
)

private let expectedHandshake = DaemonHandshakeResult.responded(
    DaemonHandshakeEvidence(
        protocolVersion: 1,
        daemonBuild: "daemon-new",
        reconciliation: .healthy
    )
)

private let staleHandshake = DaemonHandshakeResult.responded(
    DaemonHandshakeEvidence(
        protocolVersion: 1,
        daemonBuild: "daemon-old",
        reconciliation: .healthy
    )
)

private final class RecoveryEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ event: String) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class FakeHandshakeChecker: DaemonHandshakeChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [DaemonHandshakeResult]
    private var preparationResults: [DaemonRecoveryPreparationResult]
    private let events: RecoveryEventLog

    init(
        _ results: [DaemonHandshakeResult],
        preparationResults: [DaemonRecoveryPreparationResult] = [
            .prepared(sleepDisabledBaseline: false),
        ],
        events: RecoveryEventLog
    ) {
        self.results = results
        self.preparationResults = preparationResults
        self.events = events
    }

    func checkHandshake() async -> DaemonHandshakeResult {
        events.append("handshake")
        return nextResult()
    }

    func prepareForRefresh() async -> DaemonRecoveryPreparationResult {
        nextPreparationResult()
    }

    private func nextPreparationResult() -> DaemonRecoveryPreparationResult {
        lock.lock()
        defer { lock.unlock() }
        guard !preparationResults.isEmpty else {
            events.append("prepare:none")
            return .failed(message: "No fake preparation result remained.")
        }
        let result = preparationResults.removeFirst()
        switch result {
        case .prepared(let baseline):
            events.append("prepare:\(baseline ? 1 : 0)")
        case .failed:
            events.append("prepare:failed")
        }
        return result
    }

    private func nextResult() -> DaemonHandshakeResult {
        lock.lock()
        defer { lock.unlock() }
        guard !results.isEmpty else {
            return .failed(message: "No fake handshake result remained.")
        }
        return results.removeFirst()
    }
}

private final class FakeServiceController: DaemonServiceControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var stopResults: [DaemonServiceOperationResult]
    private var startResults: [DaemonServiceOperationResult]
    private let events: RecoveryEventLog

    init(
        stopResults: [DaemonServiceOperationResult] = [.succeeded],
        startResults: [DaemonServiceOperationResult] = [.succeeded],
        events: RecoveryEventLog
    ) {
        self.stopResults = stopResults
        self.startResults = startResults
        self.events = events
    }

    func stopServiceForRefresh() async -> DaemonServiceOperationResult {
        events.append("stop")
        return nextStopResult()
    }

    func startService() async -> DaemonServiceOperationResult {
        events.append("start")
        return nextStartResult()
    }

    private func nextStopResult() -> DaemonServiceOperationResult {
        lock.lock()
        defer { lock.unlock() }
        guard !stopResults.isEmpty else {
            return .failed(message: "No fake stop result remained.")
        }
        return stopResults.removeFirst()
    }

    private func nextStartResult() -> DaemonServiceOperationResult {
        lock.lock()
        defer { lock.unlock() }
        guard !startResults.isEmpty else {
            return .failed(message: "No fake start result remained.")
        }
        return startResults.removeFirst()
    }
}

private final class FakeRecoveryPersistence: DaemonRecoveryPersisting, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: DaemonRecoveryPersistenceSnapshot
    private let loadResultOverride: DaemonRecoveryPersistenceLoadResult?
    private let attemptWriteResult: DaemonRecoveryPersistenceWriteResult
    private let healthyWriteResult: DaemonRecoveryPersistenceWriteResult
    private let events: RecoveryEventLog
    private var storedAttemptWrites: [DaemonRecoveryIdentity] = []
    private var storedHealthyWrites: [DaemonRecoveryIdentity] = []

    init(
        snapshot: DaemonRecoveryPersistenceSnapshot,
        loadResultOverride: DaemonRecoveryPersistenceLoadResult? = nil,
        attemptWriteResult: DaemonRecoveryPersistenceWriteResult = .succeeded,
        healthyWriteResult: DaemonRecoveryPersistenceWriteResult = .succeeded,
        events: RecoveryEventLog
    ) {
        self.snapshot = snapshot
        self.loadResultOverride = loadResultOverride
        self.attemptWriteResult = attemptWriteResult
        self.healthyWriteResult = healthyWriteResult
        self.events = events
    }

    func loadRecoverySnapshot() -> DaemonRecoveryPersistenceLoadResult {
        events.append("load")
        lock.lock()
        defer { lock.unlock() }
        return loadResultOverride ?? .loaded(snapshot)
    }

    func recordAutomaticRefreshAttempt(
        _ identity: DaemonRecoveryIdentity
    ) -> DaemonRecoveryPersistenceWriteResult {
        events.append("attempt")
        lock.lock()
        defer { lock.unlock() }
        guard attemptWriteResult == .succeeded else { return attemptWriteResult }
        storedAttemptWrites.append(identity)
        snapshot = DaemonRecoveryPersistenceSnapshot(
            lastHealthyIdentity: snapshot.lastHealthyIdentity,
            automaticRefreshAttemptIdentity: identity
        )
        return .succeeded
    }

    func recordHealthyIdentity(
        _ identity: DaemonRecoveryIdentity
    ) -> DaemonRecoveryPersistenceWriteResult {
        events.append("healthy")
        lock.lock()
        defer { lock.unlock() }
        guard healthyWriteResult == .succeeded else { return healthyWriteResult }
        storedHealthyWrites.append(identity)
        snapshot = DaemonRecoveryPersistenceSnapshot(
            lastHealthyIdentity: identity,
            automaticRefreshAttemptIdentity: snapshot.automaticRefreshAttemptIdentity
        )
        return .succeeded
    }

    var attemptWrites: [DaemonRecoveryIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return storedAttemptWrites
    }

    var healthyWrites: [DaemonRecoveryIdentity] {
        lock.lock()
        defer { lock.unlock() }
        return storedHealthyWrites
    }
}

private func snapshot(
    healthy: DaemonRecoveryIdentity?,
    attempt: DaemonRecoveryIdentity? = nil
) -> DaemonRecoveryPersistenceSnapshot {
    DaemonRecoveryPersistenceSnapshot(
        lastHealthyIdentity: healthy,
        automaticRefreshAttemptIdentity: attempt
    )
}

private func context(
    enabled: Bool = true,
    eligible: Bool = true
) -> DaemonRecoveryContext {
    DaemonRecoveryContext(
        expectedIdentity: expectedIdentity,
        closedLidEnabled: enabled,
        mayManageService: eligible
    )
}

private func coordinator(
    handshakes: [DaemonHandshakeResult],
    preparations: [DaemonRecoveryPreparationResult] = [
        .prepared(sleepDisabledBaseline: false),
    ],
    persistence: FakeRecoveryPersistence,
    service: FakeServiceController,
    events: RecoveryEventLog
) -> DaemonRecoveryCoordinator {
    DaemonRecoveryCoordinator(
        handshakeChecker: FakeHandshakeChecker(
            handshakes,
            preparationResults: preparations,
            events: events
        ),
        serviceController: service,
        persistence: persistence,
        stateObserver: { state in events.append("state:\(state.eventName)") }
    )
}

private extension DaemonRecoveryState {
    var eventName: String {
        switch self {
        case .checking: "checking"
        case .finishingUpdate: "finishing"
        case .restartingSupport: "restarting"
        case .ready: "ready"
        case .approvalRequired: "approval"
        case .retryableFailure: "failure"
        case .ineligible: "ineligible"
        case .deferredUntilEnabled: "deferred"
        }
    }
}

@Test func recoveryIdentityRoundTripsWithoutLossyDelimiterParsing() throws {
    let identity = DaemonRecoveryIdentity(
        protocolVersion: 17,
        appBuild: "app:build/with|delimiters",
        daemonBuild: "daemon:build/with|delimiters"
    )

    let data = try JSONEncoder().encode(identity)
    let decoded = try JSONDecoder().decode(DaemonRecoveryIdentity.self, from: data)

    #expect(decoded == identity)
}

@Test func exactHealthyHandshakeIsFirstAndPersistsSuccessWithoutServiceMutation() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .ready)
    #expect(persistence.healthyWrites == [expectedIdentity])
    #expect(persistence.attemptWrites.isEmpty)
    #expect(events.events == [
        "state:checking", "handshake", "healthy", "state:ready",
    ])
}

@Test func healthyStateIsNotReportedWhenTheVerifiedIdentityCannotBePersisted() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        healthyWriteResult: .failed(message: "defaults write failed"),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .retryableFailure(.persistenceFailed(
        message: "defaults write failed"
    )))
    #expect(persistence.healthyWrites.isEmpty)
    #expect(events.events == [
        "state:checking", "handshake", "healthy", "state:failure",
    ])
}

@Test func genuineBuildChangeRefreshesOnceWithAttemptPersistedBeforeMutation() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake, expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .ready)
    #expect(persistence.attemptWrites == [expectedIdentity])
    #expect(persistence.healthyWrites == [expectedIdentity])
    #expect(events.events == [
        "state:checking", "handshake", "load", "attempt",
        "state:finishing", "prepare:0", "stop", "state:restarting", "start",
        "handshake", "healthy", "state:ready",
    ])
}

@Test func refreshPreservesThePreparedOneBaselineAndPreparesBeforeStopping() async throws {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake, expectedHandshake],
        preparations: [.prepared(sleepDisabledBaseline: true)],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .ready)
    let recordedEvents = events.events
    let prepareIndex = try #require(recordedEvents.firstIndex(of: "prepare:1"))
    let stopIndex = try #require(recordedEvents.firstIndex(of: "stop"))
    #expect(prepareIndex < stopIndex)
}

@Test(arguments: [
    DaemonRecoveryTrigger.automaticLaunch,
    .userRequestedRetry,
    .userRequestedSetup,
])
func refusedPreparationNeverUnregisters(
    trigger: DaemonRecoveryTrigger
) async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake],
        preparations: [.failed(message: "an active holder still owns the hold")],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context(), trigger: trigger)

    #expect(result == .retryableFailure(.upgradePreparationFailed(
        message: "an active holder still owns the hold"
    )))
    #expect(events.events.contains("prepare:failed"))
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
}

@Test(arguments: [
    DaemonHandshakeResult.failed(message: "XPC unavailable"),
    .timedOut,
    .responded(DaemonHandshakeEvidence(
        protocolVersion: 2,
        daemonBuild: "daemon-old",
        reconciliation: .healthy
    )),
])
func buildChangeWithoutAuthenticatedSameProtocolReadinessNeverUnregisters(
    handshake: DaemonHandshakeResult
) async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [handshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    guard case .retryableFailure = result else {
        Issue.record("Expected a non-mutating recovery failure, got \(result)")
        return
    }
    #expect(persistence.attemptWrites.isEmpty)
    #expect(!events.events.contains { $0.hasPrefix("prepare:") })
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
}

@Test func failedAutomaticAttemptCannotLoopOnTheSameExpectedIdentity() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(
        startResults: [.failed(message: "registration failed")],
        events: events
    )
    let recovery = coordinator(
        handshakes: [staleHandshake, staleHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let first = await recovery.run(context: context())
    let second = await recovery.run(context: context())

    #expect(first == .retryableFailure(.serviceStartFailed(message: "registration failed")))
    #expect(second == .retryableFailure(.automaticRefreshAlreadyAttempted(
        message: "Automatic recovery was already attempted for this build. Choose Retry to try again."
    )))
    #expect(persistence.attemptWrites == [expectedIdentity])
    #expect(persistence.healthyWrites.isEmpty)
    #expect(events.events.count { $0 == "stop" } == 1)
    #expect(events.events.count { $0 == "start" } == 1)
}

@Test func attemptGuardWriteMustSucceedBeforeAnyServiceMutation() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        attemptWriteResult: .failed(message: "defaults unavailable"),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .retryableFailure(.persistenceFailed(message: "defaults unavailable")))
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
    #expect(persistence.healthyWrites.isEmpty)
}

@Test func freshInstallRequiresExplicitSetupAfterHandshakeFailure() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: nil),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [.failed(message: "not registered")],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .retryableFailure(.explicitSetupRequired(
        message: "Choose Set Up to enable closed-lid support on this Mac."
    )))
    #expect(DaemonRecoveryPresentation(state: result).actions == [.setUp])
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
}

@Test func explicitFreshSetupStartsWithoutUnregisteringAndVerifiesExactly() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: nil),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [.failed(message: "not registered"), expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(
        context: context(),
        trigger: .userRequestedSetup
    )

    #expect(result == .ready)
    #expect(!events.events.contains("stop"))
    #expect(events.events.count { $0 == "start" } == 1)
    #expect(persistence.attemptWrites.isEmpty)
    #expect(persistence.healthyWrites == [expectedIdentity])
}

@Test func explicitSetupRefreshesAnAuthenticatedStaleServiceEvenWithoutHistory() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: nil),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake, expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(
        context: context(),
        trigger: .userRequestedSetup
    )

    #expect(result == .ready)
    #expect(events.events.count { $0 == "stop" } == 1)
    #expect(events.events.count { $0 == "start" } == 1)
    #expect(persistence.attemptWrites.isEmpty)
    #expect(persistence.healthyWrites == [expectedIdentity])
}

@Test func explicitClosedLidOffDefersMutationAfterHandshake() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context(enabled: false))

    #expect(result == .deferredUntilEnabled)
    #expect(events.events == ["state:checking", "handshake", "state:deferred"])
    #expect(!DaemonRecoveryPresentation(state: result).requiresAttention)
    #expect(persistence.attemptWrites.isEmpty)
    #expect(persistence.healthyWrites.isEmpty)
}

@Test func explicitClosedLidOffStillRecordsAnAlreadyHealthyBuild() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context(enabled: false))

    #expect(result == .ready)
    #expect(persistence.healthyWrites == [expectedIdentity])
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
}

@Test func explicitRetryMayRunAfterTheAutomaticGuardWithoutRewritingIt() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity, attempt: expectedIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake, expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(
        context: context(),
        trigger: .userRequestedRetry
    )

    #expect(result == .ready)
    #expect(persistence.attemptWrites.isEmpty)
    #expect(events.events.count { $0 == "stop" } == 1)
    #expect(events.events.count { $0 == "start" } == 1)
}

@Test func postRefreshMismatchNeverPersistsSuccess() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [staleHandshake, staleHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .retryableFailure(.unexpectedDaemonBuild(
        expected: "daemon-new",
        received: "daemon-old"
    )))
    #expect(persistence.attemptWrites == [expectedIdentity])
    #expect(persistence.healthyWrites.isEmpty)
}

@Test(arguments: [
    (
        DaemonHandshakeResult.responded(DaemonHandshakeEvidence(
            protocolVersion: 2,
            daemonBuild: "daemon-new",
            reconciliation: .healthy
        )),
        DaemonRecoveryFailure.incompatibleProtocol(expected: 1, received: 2)
    ),
    (
        DaemonHandshakeResult.responded(DaemonHandshakeEvidence(
            protocolVersion: 1,
            daemonBuild: "daemon-old",
            reconciliation: .healthy
        )),
        DaemonRecoveryFailure.unexpectedDaemonBuild(
            expected: "daemon-new",
            received: "daemon-old"
        )
    ),
    (
        DaemonHandshakeResult.responded(DaemonHandshakeEvidence(
            protocolVersion: 1,
            daemonBuild: "daemon-new",
            reconciliation: .blocked(message: "restore debt remains")
        )),
        DaemonRecoveryFailure.reconciliationBlocked(message: "restore debt remains")
    ),
    (
        DaemonHandshakeResult.timedOut,
        DaemonRecoveryFailure.handshakeTimedOut
    ),
])
func sameBuildFailuresDoNotAutomaticallyRefresh(
    handshake: DaemonHandshakeResult,
    failure: DaemonRecoveryFailure
) async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: expectedIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [handshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context())

    #expect(result == .retryableFailure(failure))
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
    #expect(persistence.attemptWrites.isEmpty)
}

@Test(arguments: [
    DaemonRecoveryTrigger.automaticLaunch,
    .userRequestedRetry,
    .userRequestedSetup,
])
func blockedReconciliationNeverStopsTheDaemon(
    trigger: DaemonRecoveryTrigger
) async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let blocked = DaemonHandshakeResult.responded(DaemonHandshakeEvidence(
        protocolVersion: expectedIdentity.protocolVersion,
        daemonBuild: oldIdentity.daemonBuild,
        reconciliation: .blocked(message: "restore debt remains")
    ))
    let recovery = coordinator(
        handshakes: [blocked],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context(), trigger: trigger)

    #expect(result == .retryableFailure(.reconciliationBlocked(
        message: "restore debt remains"
    )))
    #expect(!events.events.contains("stop"))
    #expect(!events.events.contains("start"))
    #expect(persistence.attemptWrites.isEmpty)
    #expect(persistence.healthyWrites.isEmpty)
}

@Test func onlyPositiveApprovalEvidenceShowsBackgroundItemsAction() async {
    let approvalEvents = RecoveryEventLog()
    let approvalPersistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: approvalEvents
    )
    let approvalService = FakeServiceController(events: approvalEvents)
    let approvalRecovery = coordinator(
        handshakes: [.approvalRequired(message: "Enable Let It Brew in Background Items.")],
        persistence: approvalPersistence,
        service: approvalService,
        events: approvalEvents
    )
    let approval = await approvalRecovery.run(context: context())

    let failureEvents = RecoveryEventLog()
    let failurePersistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: expectedIdentity),
        events: failureEvents
    )
    let failureService = FakeServiceController(events: failureEvents)
    let failureRecovery = coordinator(
        handshakes: [.failed(message: "XPC interrupted")],
        persistence: failurePersistence,
        service: failureService,
        events: failureEvents
    )
    let failure = await failureRecovery.run(context: context())

    #expect(approval == .approvalRequired(
        message: "Enable Let It Brew in Background Items."
    ))
    let presentation = DaemonRecoveryPresentation(state: approval)
    #expect(presentation.actions == [.openBackgroundItems])
    #expect(approvalEvents.events == [
        "state:checking", "handshake", "state:approval",
    ])
    #expect(DaemonRecoveryPresentation(state: failure).actions == [.retry])
}

@Test func ineligibleCopyNeverChecksOrMutatesTheService() async {
    let events = RecoveryEventLog()
    let persistence = FakeRecoveryPersistence(
        snapshot: snapshot(healthy: oldIdentity),
        events: events
    )
    let service = FakeServiceController(events: events)
    let recovery = coordinator(
        handshakes: [expectedHandshake],
        persistence: persistence,
        service: service,
        events: events
    )

    let result = await recovery.run(context: context(eligible: false))

    #expect(result == .ineligible(
        message: "Run the correctly signed Let It Brew app directly from /Applications."
    ))
    #expect(events.events == ["state:ineligible"])
    #expect(persistence.healthyWrites.isEmpty)
}

@Test func presentationCopyAndAttentionAreStateSpecific() {
    let cases: [(DaemonRecoveryState, String, [DaemonRecoveryUserAction], Bool, Bool)] = [
        (.checking, "Checking closed-lid support…", [], true, false),
        (.finishingUpdate, "Finishing update…", [], true, false),
        (.restartingSupport, "Restarting closed-lid support…", [], true, false),
        (.ready, "Closed-lid support is ready.", [], false, false),
        (
            .approvalRequired(message: "Approval needed."),
            "Closed-lid support needs approval",
            [.retry, .openBackgroundItems],
            false,
            true
        ),
        (
            .retryableFailure(.handshakeTimedOut),
            "Closed-lid support couldn’t restart.",
            [.retry],
            false,
            true
        ),
        (
            .ineligible(message: "Wrong location."),
            "Closed-lid support is unavailable from this copy.",
            [],
            false,
            true
        ),
        (
            .deferredUntilEnabled,
            "Closed-lid support is off.",
            [],
            false,
            false
        ),
    ]

    for (state, headline, actions, progress, attention) in cases {
        let presentation = DaemonRecoveryPresentation(state: state)
        #expect(presentation.headline == headline)
        #expect(presentation.actions == actions)
        #expect(presentation.showsProgress == progress)
        #expect(presentation.requiresAttention == attention)
    }
}
