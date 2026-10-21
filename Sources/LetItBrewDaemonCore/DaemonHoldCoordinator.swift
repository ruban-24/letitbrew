import Foundation
import LetItBrewCore

public enum DaemonReconciliationResult: Equatable, Sendable {
    case clean
    case clearedAlreadyRestored(priorValue: Bool)
    case restored(priorValue: Bool)
    case blocked(String)

    public var succeeded: Bool {
        switch self {
        case .clean, .clearedAlreadyRestored, .restored: true
        case .blocked: false
        }
    }
}

public enum DaemonHoldResult: Equatable, Sendable {
    case applied
    case failed(String)

    public var reply: (succeeded: Bool, message: String?) {
        switch self {
        case .applied: (true, nil)
        case .failed(let message): (false, message)
        }
    }
}

/// A Low Power Mode request's outcome. `personalSources` are the sources that
/// were already in Low Power Mode before Let It Brew switched any: that mode is
/// the person's own choice, so "Respect Low Power Mode" still applies to it.
public enum DaemonLowPowerHoldResult: Equatable, Sendable {
    case applied(personalSources: Set<PowerModeSource>)
    case failed(String)

    /// XPC-safe reply: success, message, and a bitmask of personal sources
    /// (1 battery, 2 charger), or -1 on failure.
    public var reply: (succeeded: Bool, message: String?, personalSources: Int) {
        switch self {
        case .applied(let sources):
            (true, nil, PowerModeSource.mask(sources))
        case .failed(let message):
            (false, message, -1)
        }
    }
}

public enum DaemonReconciliationReadiness: Equatable, Sendable {
    case ready
    case blocked(String)

    public var reply: (ready: Bool, message: String?) {
        switch self {
        case .ready: (true, nil)
        case .blocked(let message): (false, message)
        }
    }
}

public enum DaemonUpgradePreparationResult: Equatable, Sendable {
    case ready(baseline: Bool)
    case failed(String)

    public var reply: (succeeded: Bool, message: String?, baseline: Int) {
        switch self {
        case .ready(let baseline): (true, nil, baseline ? 1 : 0)
        case .failed(let message): (false, message, -1)
        }
    }
}

/// Serializes all clients around the single global `disablesleep` setting.
/// A connection identifier may acquire at most one hold, holds union across
/// clients, and the last release reconciles the durable debt.
///
/// A client that owns a lid-closed hold may also switch the Mac to Low Power
/// Mode. That hold is nested inside the lid-closed one: releasing the
/// lid-closed hold, or disconnecting, releases it too, and the last release
/// restores each source's exact recorded energy mode. Low Power Mode never
/// gates `disablesleep`: a failure to switch or restore it is reported, but
/// cannot keep a Mac awake or block a lid-closed hold.
public final class DaemonHoldCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let debtStore: DaemonSleepDebtStoring
    private let sleepControl: DaemonSleepSettingControlling
    private let powerModeDebtStore: DaemonPowerModeDebtStoring?
    private let powerModeControl: DaemonPowerModeControlling?
    private let now: () -> Date
    private let pauseBeforeRetry: (TimeInterval) -> Void
    private var holders: Set<UUID> = []
    private var lowPowerHolders: Set<UUID> = []
    /// Non-nil only after a successful upgrade preparation. The daemon then
    /// remains quiesced until exit, closing the race between the baseline reply
    /// and service unregistration.
    private var preparedUpgradeBaseline: Bool?

    /// Energy mode restore attempts before an upgrade or uninstall proceeds.
    static let upgradeRestoreAttempts = 3
    static let upgradeRestoreRetryDelay: TimeInterval = 0.5

    public init(
        debtStore: DaemonSleepDebtStoring,
        sleepControl: DaemonSleepSettingControlling,
        powerModeDebtStore: DaemonPowerModeDebtStoring? = nil,
        powerModeControl: DaemonPowerModeControlling? = nil,
        now: @escaping () -> Date = Date.init,
        pauseBeforeRetry: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.debtStore = debtStore
        self.sleepControl = sleepControl
        self.powerModeDebtStore = powerModeDebtStore
        self.powerModeControl = powerModeControl
        self.now = now
        self.pauseBeforeRetry = pauseBeforeRetry
    }

    public var holdCount: Int {
        withLock { holders.count }
    }

    public var lowPowerHoldCount: Int {
        withLock { lowPowerHolders.count }
    }

    /// Restores an energy mode the previous daemon run left switched. Called
    /// at launch beside `reconcileAtLaunch`, and independent of it.
    @discardableResult
    public func reconcilePowerModeAtLaunch() -> DaemonReconciliationResult {
        withLock { reconcilePowerModeDebt() }
    }

    /// Switches every power source to Low Power Mode for a client that owns a
    /// lid-closed hold, or releases that client's switch.
    public func setLowPowerMode(
        _ enabled: Bool,
        for connectionID: UUID
    ) -> DaemonLowPowerHoldResult {
        withLock {
            if enabled { return acquireLowPower(for: connectionID) }
            switch releaseLowPower(for: connectionID) {
            case .applied: return .applied(personalSources: [])
            case .failed(let message): return .failed(message)
            }
        }
    }

    /// Called before the XPC listener starts. A valid marker is authoritative:
    /// it records exactly what this daemon promised to restore before the
    /// previous boot ended.
    @discardableResult
    public func reconcileAtLaunch() -> DaemonReconciliationResult {
        withLock { reconcileDebt() }
    }

    /// Rechecks unresolved launch debt for each authenticated handshake. Active
    /// holders imply that acquisition already completed reconciliation while
    /// holding this same lock, so their intentional debt must not be restored.
    public func reconciliationReadiness() -> DaemonReconciliationReadiness {
        withLock {
            guard holders.isEmpty else { return .ready }
            // Retries an energy mode restore that failed earlier. It never
            // affects readiness: Low Power Mode cannot keep the Mac awake.
            if lowPowerHolders.isEmpty { _ = reconcilePowerModeDebt() }
            switch reconcileDebt() {
            case .clean, .clearedAlreadyRestored, .restored:
                return .ready
            case .blocked(let message):
                return .blocked(message)
            }
        }
    }

    /// Returns the exact live baseline only after all owned debt is reconciled.
    /// Existing holders are rejected before any read, write, or debt mutation.
    public func prepareForUpgrade() -> DaemonUpgradePreparationResult {
        withLock {
            if let preparedUpgradeBaseline {
                return .ready(baseline: preparedUpgradeBaseline)
            }
            guard holders.isEmpty else {
                return .failed(
                    "Cannot prepare the daemon upgrade while a client still owns a lid-closed hold."
                )
            }

            switch reconcileDebt() {
            case .clean, .clearedAlreadyRestored, .restored:
                break
            case .blocked(let message):
                return .failed(message)
            }
            // Restore the energy mode before an upgrade or uninstall, retrying
            // a passing failure, because no daemon follows an uninstall. A
            // restore that still fails never blocks either: a later daemon
            // reconciles the same record at launch, Low Power Mode cannot keep
            // the Mac awake, and a record that can never be restored must not
            // strand the upgrade or uninstall itself.
            for attempt in 0..<Self.upgradeRestoreAttempts {
                if case .blocked = reconcilePowerModeDebt() {
                    if attempt + 1 < Self.upgradeRestoreAttempts {
                        pauseBeforeRetry(Self.upgradeRestoreRetryDelay)
                    }
                    continue
                }
                break
            }

            guard let baseline = sleepControl.readDisabled() else {
                return .failed(
                    "Could not read disablesleep after reconciling the daemon restore record."
                )
            }
            preparedUpgradeBaseline = baseline
            return .ready(baseline: baseline)
        }
    }

    public func setHold(_ enabled: Bool, for connectionID: UUID) -> DaemonHoldResult {
        withLock {
            enabled
                ? acquire(for: connectionID)
                : release(for: connectionID)
        }
    }

    @discardableResult
    public func connectionInvalidated(_ connectionID: UUID) -> DaemonHoldResult {
        setHold(false, for: connectionID)
    }

    private func acquire(for connectionID: UUID) -> DaemonHoldResult {
        guard preparedUpgradeBaseline == nil else {
            return .failed(
                "The daemon is quiescing for an upgrade and cannot acquire a new hold."
            )
        }
        if holders.contains(connectionID) { return .applied }
        if !holders.isEmpty {
            holders.insert(connectionID)
            return .applied
        }

        let pending = reconcileDebt()
        guard pending.succeeded else {
            if case .blocked(let message) = pending { return .failed(message) }
            return .failed("The previous lid-closed hold could not be reconciled.")
        }

        guard let priorValue = sleepControl.readDisabled() else {
            return .failed("Could not read the current disablesleep value.")
        }

        let debt = DaemonSleepDebt(priorValue: priorValue, setAt: now())
        guard debtStore.save(debt) else {
            return .failed("Could not persist the disablesleep restore record.")
        }

        if !priorValue {
            guard sleepControl.writeDisabled(true), sleepControl.readDisabled() == true else {
                let cleanup = reconcileDebt()
                if !cleanup.succeeded {
                    return .failed(
                        "Could not confirm disablesleep=1; the restore record remains for recovery."
                    )
                }
                return .failed("Could not confirm disablesleep=1.")
            }
        }

        holders.insert(connectionID)
        return .applied
    }

    private func release(for connectionID: UUID) -> DaemonHoldResult {
        // Low Power Mode is nested in the lid-closed hold, so it goes first.
        // Its restore failure never keeps disablesleep held. The app's
        // periodic release confirmation retries a restore that failed.
        _ = releaseLowPower(for: connectionID)
        guard holders.remove(connectionID) != nil else { return .applied }
        guard holders.isEmpty else { return .applied }

        let result = reconcileDebt()
        switch result {
        case .clean, .clearedAlreadyRestored, .restored:
            return .applied
        case .blocked(let message):
            return .failed(message)
        }
    }

    private func acquireLowPower(for connectionID: UUID) -> DaemonLowPowerHoldResult {
        guard preparedUpgradeBaseline == nil else {
            return .failed(
                "The daemon is quiescing for an upgrade and cannot switch to Low Power Mode."
            )
        }
        guard let powerModeControl, let powerModeDebtStore else {
            return .failed("This daemon cannot change Low Power Mode.")
        }
        guard holders.contains(connectionID) else {
            return .failed("Low Power Mode requires this client's lid-closed hold.")
        }
        if !lowPowerHolders.isEmpty {
            guard case .valid(let debt) = powerModeDebtStore.load() else {
                return .failed("The energy mode restore record is missing for an active switch.")
            }
            lowPowerHolders.insert(connectionID)
            return .applied(personalSources: Self.personalSources(debt.prior))
        }

        if case .blocked(let message) = reconcilePowerModeDebt() {
            return .failed(message)
        }
        guard let prior = powerModeControl.readPowerModes() else {
            return .failed("Could not read the current energy mode.")
        }
        guard !prior.sources.isEmpty else {
            return .failed("This Mac does not report an energy mode Let It Brew can switch.")
        }

        let debt = DaemonPowerModeDebt(prior: prior, setAt: now())
        guard powerModeDebtStore.save(debt) else {
            return .failed("Could not persist the energy mode restore record.")
        }

        for source in prior.sources {
            guard let current = prior[source], current.value != PowerModeValue.lowPower else {
                continue
            }
            let target = PowerModeValue(key: current.key, value: PowerModeValue.lowPower)
            guard powerModeControl.writePowerMode(target, for: source) else {
                return failLowPowerAcquisition("Could not switch to Low Power Mode.")
            }
        }
        guard powerModeControl.readPowerModes()?.isLowPowerEverywhere == true else {
            return failLowPowerAcquisition("Could not confirm Low Power Mode.")
        }

        lowPowerHolders.insert(connectionID)
        return .applied(personalSources: Self.personalSources(prior))
    }

    private static func personalSources(_ prior: PowerModeSnapshot) -> Set<PowerModeSource> {
        Set(prior.sources.filter { prior[$0]?.value == PowerModeValue.lowPower })
    }

    private func failLowPowerAcquisition(_ message: String) -> DaemonLowPowerHoldResult {
        if case .blocked = reconcilePowerModeDebt() {
            return .failed("\(message) The energy mode restore record remains for recovery.")
        }
        return .failed(message)
    }

    /// With no holder left, every release also retries a restore an earlier
    /// release could not finish. Without a record that costs one file read.
    private func releaseLowPower(for connectionID: UUID) -> DaemonHoldResult {
        lowPowerHolders.remove(connectionID)
        guard lowPowerHolders.isEmpty else { return .applied }
        switch reconcilePowerModeDebt() {
        case .clean, .clearedAlreadyRestored, .restored:
            return .applied
        case .blocked(let message):
            return .failed(message)
        }
    }

    /// Restores each recorded source to its exact prior energy mode. Unlike
    /// `disablesleep`, an unreadable record is cleared without guessing a
    /// value: Low Power Mode cannot keep a Mac awake, and blocking on it would
    /// strand every later closed-lid hold.
    private func reconcilePowerModeDebt() -> DaemonReconciliationResult {
        guard let powerModeDebtStore else { return .clean }
        switch powerModeDebtStore.load() {
        case .none:
            return .clean

        case .unreadable:
            guard powerModeDebtStore.remove() else {
                return .blocked("Could not remove the unreadable energy mode restore record.")
            }
            return .clearedAlreadyRestored(priorValue: false)

        case .valid(let debt):
            guard let powerModeControl,
                  let live = powerModeControl.readPowerModes()
            else {
                return .blocked("Could not read the energy mode while restoring it.")
            }
            // Values, not names, are compared and restored: a macOS update can
            // rename `lowpowermode` to `powermode` between switch and restore,
            // so each write uses the name the live system reports.
            var changed = false
            for source in debt.prior.sources {
                guard let prior = debt.prior[source], let current = live[source] else { continue }
                guard current.value != prior.value else { continue }
                let restore = PowerModeValue(key: current.key, value: prior.value)
                guard powerModeControl.writePowerMode(restore, for: source) else {
                    return .blocked(
                        "Could not restore the energy mode; the restore record remains."
                    )
                }
                changed = true
            }
            if changed {
                guard let restored = powerModeControl.readPowerModes(),
                      debt.prior.sources.allSatisfy({ source in
                          live[source] == nil
                              || restored[source]?.value == debt.prior[source]?.value
                      })
                else {
                    return .blocked(
                        "Could not confirm the restored energy mode; the restore record remains."
                    )
                }
            }
            // A recorded source missing from the reading was not restored, so
            // the record stays until every source reads back.
            guard debt.prior.sources.allSatisfy({ live[$0] != nil }) else {
                return .blocked(
                    "A recorded power source is missing from the energy mode; the restore record remains."
                )
            }
            guard powerModeDebtStore.remove() else {
                return .blocked(
                    "The energy mode was restored, but its restore record could not be removed."
                )
            }
            return changed
                ? .restored(priorValue: false)
                : .clearedAlreadyRestored(priorValue: false)
        }
    }

    private func reconcileDebt() -> DaemonReconciliationResult {
        switch debtStore.load() {
        case .none:
            return .clean

        case .unreadable:
            guard let live = sleepControl.readDisabled() else {
                return .blocked(
                    "The restore record and current disablesleep value are unreadable."
                )
            }
            guard !live else {
                return .blocked(
                    "The restore record is unreadable while disablesleep=1; refusing to guess ownership."
                )
            }
            guard debtStore.remove() else {
                return .blocked("Could not remove the unreadable restore record.")
            }
            return .clearedAlreadyRestored(priorValue: false)

        case .valid(let debt):
            guard let live = sleepControl.readDisabled() else {
                return .blocked("Could not read disablesleep while reconciling its restore record.")
            }

            if live != debt.priorValue {
                guard sleepControl.writeDisabled(debt.priorValue),
                      sleepControl.readDisabled() == debt.priorValue
                else {
                    return .blocked(
                        "Could not restore disablesleep to \(debt.priorValue ? 1 : 0); the restore record remains."
                    )
                }
                guard debtStore.remove() else {
                    return .blocked(
                        "disablesleep was restored, but its restore record could not be removed."
                    )
                }
                return .restored(priorValue: debt.priorValue)
            }

            guard debtStore.remove() else {
                return .blocked("Could not remove the completed disablesleep restore record.")
            }
            return .clearedAlreadyRestored(priorValue: debt.priorValue)
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
