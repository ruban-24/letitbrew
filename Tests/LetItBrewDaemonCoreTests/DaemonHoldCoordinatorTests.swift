import Foundation
import Testing
@testable import LetItBrewDaemonCore

private final class FakeDebtStore: DaemonSleepDebtStoring {
    var state: DaemonSleepDebtState
    var saveSucceeds = true
    var removeSucceeds = true
    var events: [String]

    init(state: DaemonSleepDebtState = .none, events: [String] = []) {
        self.state = state
        self.events = events
    }

    func load() -> DaemonSleepDebtState {
        events.append("load")
        return state
    }

    func save(_ debt: DaemonSleepDebt) -> Bool {
        events.append("save-\(debt.priorValue ? 1 : 0)")
        guard saveSucceeds else { return false }
        state = .valid(debt)
        return true
    }

    func remove() -> Bool {
        events.append("remove")
        guard removeSucceeds else { return false }
        state = .none
        return true
    }
}

private final class FakeSleepControl: DaemonSleepSettingControlling {
    var live: Bool?
    var writeSucceeds = true
    var events: [String]

    init(live: Bool?, events: [String] = []) {
        self.live = live
        self.events = events
    }

    func readDisabled() -> Bool? {
        events.append("read")
        return live
    }

    func writeDisabled(_ disabled: Bool) -> Bool {
        events.append("write-\(disabled ? 1 : 0)")
        guard writeSucceeds else { return false }
        live = disabled
        return true
    }
}

@Test func bootRestoresAValidDebtThenDeletesIt() {
    let debt = DaemonSleepDebt(priorValue: false, setAt: Date(timeIntervalSince1970: 10))
    let store = FakeDebtStore(state: .valid(debt))
    let sleep = FakeSleepControl(live: true)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(coordinator.reconcileAtLaunch() == .restored(priorValue: false))
    #expect(sleep.live == false)
    #expect(sleep.events == ["read", "write-0", "read"])
    #expect(store.state == .none)
}

@Test func bootClearsDebtWhenPowerFailedBeforeTheSettingChanged() {
    let debt = DaemonSleepDebt(priorValue: false, setAt: Date(timeIntervalSince1970: 10))
    let store = FakeDebtStore(state: .valid(debt))
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(
        coordinator.reconcileAtLaunch()
            == .clearedAlreadyRestored(priorValue: false)
    )
    #expect(sleep.events == ["read"])
    #expect(store.state == .none)
}

@Test func bootNeverGuessesWhenDebtIsUnreadableAndSleepIsDisabled() {
    let store = FakeDebtStore(state: .unreadable)
    let sleep = FakeSleepControl(live: true)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    guard case .blocked = coordinator.reconcileAtLaunch() else {
        Issue.record("Expected unreadable debt to block reconciliation")
        return
    }
    #expect(sleep.events == ["read"])
    #expect(store.state == .unreadable)
}

@Test func bootCanClearUnreadableDebtOnceSleepIsAlreadyEnabled() {
    let store = FakeDebtStore(state: .unreadable)
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(
        coordinator.reconcileAtLaunch()
            == .clearedAlreadyRestored(priorValue: false)
    )
    #expect(store.state == .none)
}

@Test func handshakeReadinessRetriesAndReportsBlockedLaunchDebt() {
    let store = FakeDebtStore(state: .unreadable)
    let sleep = FakeSleepControl(live: true)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(coordinator.reconciliationReadiness() == .blocked(
        "The restore record is unreadable while disablesleep=1; refusing to guess ownership."
    ))
    #expect(store.state == .unreadable)
    #expect(store.events == ["load"])
    #expect(sleep.events == ["read"])
}

@Test func handshakeReadinessCanRecoverDebtThatBecomesReconcilable() {
    let debt = DaemonSleepDebt(
        priorValue: false,
        setAt: Date(timeIntervalSince1970: 10)
    )
    let store = FakeDebtStore(state: .valid(debt))
    let sleep = FakeSleepControl(live: nil)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    guard case .blocked = coordinator.reconciliationReadiness() else {
        Issue.record("Expected the unreadable live value to block readiness")
        return
    }
    sleep.live = true
    #expect(coordinator.reconciliationReadiness() == .ready)
    #expect(store.state == .none)
    #expect(sleep.live == false)
    #expect(store.events == ["load", "load", "remove"])
    #expect(sleep.events == ["read", "read", "write-0", "read"])
}

@Test func handshakeReadinessNeverReconcilesAnIntentionalActiveHold() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(coordinator.setHold(true, for: UUID()) == .applied)
    let storeEvents = store.events
    let sleepEvents = sleep.events

    #expect(coordinator.reconciliationReadiness() == .ready)
    #expect(store.events == storeEvents)
    #expect(sleep.events == sleepEvents)
    #expect(coordinator.holdCount == 1)
    #expect(sleep.live == true)
}

@Test func upgradePreparationReturnsExactReadableZeroAndOneBaselines() {
    for baseline in [false, true] {
        let store = FakeDebtStore()
        let sleep = FakeSleepControl(live: baseline)
        let coordinator = DaemonHoldCoordinator(
            debtStore: store,
            sleepControl: sleep
        )

        let result = coordinator.prepareForUpgrade()

        #expect(result == .ready(baseline: baseline))
        #expect(result.reply.succeeded)
        #expect(result.reply.message == nil)
        #expect(result.reply.baseline == (baseline ? 1 : 0))
        #expect(store.events == ["load"])
        #expect(sleep.events == ["read"])
        #expect(sleep.live == baseline)
    }
}

@Test func successfulUpgradePreparationQuiescesAllFutureAcquisitionsUntilExit() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(coordinator.prepareForUpgrade() == .ready(baseline: false))
    let storeEvents = store.events
    let sleepEvents = sleep.events

    guard case .failed(let message) = coordinator.setHold(true, for: UUID()) else {
        Issue.record("Expected a prepared daemon to refuse every new hold")
        return
    }
    #expect(message.contains("quiescing"))
    #expect(coordinator.holdCount == 0)
    #expect(store.events == storeEvents)
    #expect(sleep.events == sleepEvents)

    // Preparation is idempotent and returns the originally verified baseline
    // without another read or any opportunity to clear the quiescing latch.
    sleep.live = true
    #expect(coordinator.prepareForUpgrade() == .ready(baseline: false))
    #expect(store.events == storeEvents)
    #expect(sleep.events == sleepEvents)
}

@Test func failedUpgradePreparationDoesNotQuiesceTheDaemon() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: nil)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    guard case .failed = coordinator.prepareForUpgrade() else {
        Issue.record("Expected an unreadable baseline to fail preparation")
        return
    }
    sleep.live = false

    #expect(coordinator.setHold(true, for: UUID()) == .applied)
    #expect(coordinator.holdCount == 1)
    #expect(sleep.live == true)
}

@Test func upgradePreparationRefusesActiveHoldersBeforeTouchingState() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(coordinator.setHold(true, for: UUID()) == .applied)
    let storeEvents = store.events
    let sleepEvents = sleep.events

    guard case .failed = coordinator.prepareForUpgrade() else {
        Issue.record("Expected an active holder to block upgrade preparation")
        return
    }
    #expect(store.events == storeEvents)
    #expect(sleep.events == sleepEvents)
    #expect(coordinator.holdCount == 1)
    #expect(sleep.live == true)
}

@Test func upgradePreparationReconcilesDebtBeforeReportingBaseline() {
    let debt = DaemonSleepDebt(
        priorValue: false,
        setAt: Date(timeIntervalSince1970: 10)
    )
    let store = FakeDebtStore(state: .valid(debt))
    let sleep = FakeSleepControl(live: true)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    #expect(coordinator.prepareForUpgrade() == .ready(baseline: false))
    #expect(store.state == .none)
    #expect(store.events == ["load", "remove"])
    #expect(sleep.events == ["read", "write-0", "read", "read"])
}

@Test func upgradePreparationNeverGuessesAnUnreadableBaseline() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: nil)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    let result = coordinator.prepareForUpgrade()

    guard case .failed = result else {
        Issue.record("Expected an unreadable baseline to fail preparation")
        return
    }
    #expect(!result.reply.succeeded)
    #expect(result.reply.baseline == -1)
    #expect(result.reply.message != nil)
    #expect(store.events == ["load"])
    #expect(sleep.events == ["read"])
}

@Test func upgradePreparationPreservesBlockedDebtAndReturnsNoBaseline() {
    let debt = DaemonSleepDebt(
        priorValue: false,
        setAt: Date(timeIntervalSince1970: 10)
    )
    let store = FakeDebtStore(state: .valid(debt))
    let sleep = FakeSleepControl(live: true)
    sleep.writeSucceeds = false
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    let result = coordinator.prepareForUpgrade()

    guard case .failed = result else {
        Issue.record("Expected failed restoration to block preparation")
        return
    }
    #expect(result.reply.baseline == -1)
    #expect(store.state == .valid(debt))
    #expect(store.events == ["load"])
    #expect(sleep.events == ["read", "write-0"])
}

@Test func firstHolderPersistsPriorBeforeChangingTheSetting() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(
        debtStore: store,
        sleepControl: sleep,
        now: { Date(timeIntervalSince1970: 123) }
    )

    let id = UUID()
    #expect(coordinator.setHold(true, for: id) == .applied)
    #expect(store.events == ["load", "save-0"])
    #expect(sleep.events == ["read", "write-1", "read"])
    #expect(coordinator.holdCount == 1)
}

@Test func failureToPersistNeverTouchesPmset() {
    let store = FakeDebtStore()
    store.saveSucceeds = false
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)

    guard case .failed = coordinator.setHold(true, for: UUID()) else {
        Issue.record("Expected acquisition to fail")
        return
    }
    #expect(sleep.events == ["read"])
    #expect(coordinator.holdCount == 0)
}

@Test func holdsUnionAndOnlyTheLastConnectionRestores() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let first = UUID()
    let second = UUID()

    #expect(coordinator.setHold(true, for: first) == .applied)
    #expect(coordinator.setHold(true, for: second) == .applied)
    #expect(coordinator.setHold(false, for: first) == .applied)
    #expect(sleep.live == true)
    #expect(coordinator.holdCount == 1)

    #expect(coordinator.connectionInvalidated(second) == .applied)
    #expect(sleep.live == false)
    #expect(coordinator.holdCount == 0)
    #expect(sleep.events == ["read", "write-1", "read", "read", "write-0", "read"])
}

@Test func aPriorManualHoldIsNeverCleared() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: true)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let id = UUID()

    #expect(coordinator.setHold(true, for: id) == .applied)
    #expect(coordinator.setHold(false, for: id) == .applied)
    #expect(sleep.live == true)
    #expect(sleep.events == ["read", "read"])
}

@Test func failedRestoreKeepsTheDebtForBootRecovery() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let id = UUID()

    #expect(coordinator.setHold(true, for: id) == .applied)
    sleep.writeSucceeds = false
    guard case .failed = coordinator.setHold(false, for: id) else {
        Issue.record("Expected release to report the failed restore")
        return
    }
    guard case .valid(let debt) = store.state else {
        Issue.record("Expected the restore record to survive")
        return
    }
    #expect(debt.priorValue == false)
}

@Test func repeatedReleaseRetriesAFailedRestore() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let id = UUID()
    #expect(coordinator.setHold(true, for: id) == .applied)
    sleep.writeSucceeds = false
    guard case .failed = coordinator.connectionInvalidated(id) else {
        Issue.record("Expected the disconnect restore to fail")
        return
    }
    #expect(coordinator.holdCount == 0)
    guard case .failed = coordinator.setHold(false, for: id) else {
        Issue.record("A repeated release must not falsely report success")
        return
    }
    sleep.writeSucceeds = true
    #expect(coordinator.setHold(false, for: id) == .applied)
    #expect(sleep.live == false)
    #expect(store.state == .none)
}

@Test func maintenanceRestoresAfterTheLastClientDisappears() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let id = UUID()
    #expect(coordinator.setHold(true, for: id) == .applied)
    sleep.writeSucceeds = false
    _ = coordinator.connectionInvalidated(id)
    coordinator.retryPendingRestoration()
    #expect(sleep.live == true)
    #expect(store.state != .none)
    sleep.writeSucceeds = true
    coordinator.retryPendingRestoration()
    #expect(sleep.live == false)
    #expect(store.state == .none)
    let events = sleep.events
    coordinator.retryPendingRestoration()
    #expect(sleep.events == events)
}

@Test func restoreRetryTimerRecoversOnItsOwnQueue() async throws {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let id = UUID()
    #expect(coordinator.setHold(true, for: id) == .applied)
    sleep.writeSucceeds = false
    _ = coordinator.connectionInvalidated(id)
    #expect(store.state != .none)
    sleep.writeSucceeds = true

    let timer = coordinator.startRestoreRetryTimer(interval: .milliseconds(10))
    defer { timer.cancel() }
    for _ in 0..<500 {
        if store.state == .none { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(sleep.live == false)
    #expect(store.state == .none)
}

@Test func maintenanceAndUnownedReleaseNeverRestoreAnActiveHold() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    let id = UUID()
    #expect(coordinator.setHold(true, for: id) == .applied)
    let events = sleep.events
    coordinator.retryPendingRestoration()
    #expect(coordinator.setHold(false, for: UUID()) == .applied)
    #expect(sleep.events == events)
    #expect(sleep.live == true)
    #expect(coordinator.holdCount == 1)
}

@Test func maintenanceHonorsUpgradeQuiescence() {
    let store = FakeDebtStore()
    let sleep = FakeSleepControl(live: false)
    let coordinator = DaemonHoldCoordinator(debtStore: store, sleepControl: sleep)
    #expect(coordinator.prepareForUpgrade() == .ready(baseline: false))
    let reads = store.events
    let events = sleep.events
    coordinator.retryPendingRestoration()
    #expect(store.events == reads)
    #expect(sleep.events == events)
}

@Test func signingIdentityDerivesTheMatchingAppAndRequirement() throws {
    let daemon = RuntimeSigningIdentity(
        identifier: "com.ruban24.letitbrew.dev.daemon",
        teamIdentifier: "MV2UL94MDC"
    )
    let app = try #require(daemon.appClientIdentity())

    #expect(app.identifier == "com.ruban24.letitbrew.dev")
    #expect(app.teamIdentifier == "MV2UL94MDC")
    #expect(
        app.codeSigningRequirement
            == "anchor apple generic and certificate leaf[subject.OU] = \"MV2UL94MDC\""
                + " and identifier \"com.ruban24.letitbrew.dev\""
    )
}
