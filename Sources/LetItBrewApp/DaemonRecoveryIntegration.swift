import Foundation
import LetItBrewAppCore
import LetItBrewDaemonCore

struct UserDefaultsDaemonRecoveryPersistence:
    DaemonRecoveryPersisting,
    @unchecked Sendable
{
    private enum Keys {
        static let lastHealthy = "daemonRecoveryLastHealthyIdentityV1"
        static let automaticAttempt = "daemonRecoveryAutomaticAttemptIdentityV1"
    }

    private let lock = NSLock()
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func loadRecoverySnapshot() -> DaemonRecoveryPersistenceLoadResult {
        withLock {
            do {
                return .loaded(DaemonRecoveryPersistenceSnapshot(
                    lastHealthyIdentity: try loadIdentity(forKey: Keys.lastHealthy),
                    automaticRefreshAttemptIdentity: try loadIdentity(
                        forKey: Keys.automaticAttempt
                    )
                ))
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }
    }

    func recordAutomaticRefreshAttempt(
        _ identity: DaemonRecoveryIdentity
    ) -> DaemonRecoveryPersistenceWriteResult {
        save(identity, forKey: Keys.automaticAttempt)
    }

    func recordHealthyIdentity(
        _ identity: DaemonRecoveryIdentity
    ) -> DaemonRecoveryPersistenceWriteResult {
        withLock {
            do {
                defaults.set(
                    try PropertyListEncoder().encode(identity),
                    forKey: Keys.lastHealthy
                )
                defaults.removeObject(forKey: Keys.automaticAttempt)
                return defaults.synchronize()
                    ? .succeeded
                    : .failed(message: "Could not persist the healthy daemon build.")
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }
    }

    private func save(
        _ identity: DaemonRecoveryIdentity,
        forKey key: String
    ) -> DaemonRecoveryPersistenceWriteResult {
        withLock {
            do {
                defaults.set(try PropertyListEncoder().encode(identity), forKey: key)
                return defaults.synchronize()
                    ? .succeeded
                    : .failed(message: "Could not persist the daemon recovery guard.")
            } catch {
                return .failed(message: error.localizedDescription)
            }
        }
    }

    private func loadIdentity(forKey key: String) throws -> DaemonRecoveryIdentity? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try PropertyListDecoder().decode(DaemonRecoveryIdentity.self, from: data)
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}

final class LiveDaemonHandshakeChecker: DaemonHandshakeChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var preparableConnection: DaemonConnection?

    deinit {
        takePreparableConnection()?.invalidate()
    }

    func checkHandshake() async -> DaemonHandshakeResult {
        takePreparableConnection()?.invalidate()
        let connection: DaemonConnection
        do {
            connection = try DaemonConnection()
        } catch {
            return .failed(message: error.localizedDescription)
        }
        let expected = connection.expectedBuildIdentity
        return await withCheckedContinuation { continuation in
            connection.connect { result in
                let evidence: DaemonHandshakeResult
                let retainForPreparation: Bool
                switch result {
                case .success(let identity):
                    retainForPreparation = false
                    evidence = .responded(DaemonHandshakeEvidence(
                        protocolVersion: LetItBrewDaemonProtocolVersion.current,
                        daemonBuild: identity.codeDirectoryHash,
                        reconciliation: .healthy
                    ))
                case .failure(let error):
                    if let failure = error as? DaemonConnectionFailure,
                       case .staleBuild = failure {
                        retainForPreparation = true
                    } else {
                        retainForPreparation = false
                    }
                    evidence = Self.map(error, expected: expected)
                }
                if retainForPreparation {
                    self.storePreparableConnection(connection)
                } else {
                    connection.invalidate()
                }
                continuation.resume(returning: evidence)
            }
        }
    }

    func prepareForRefresh() async -> DaemonRecoveryPreparationResult {
        guard let connection = takePreparableConnection() else {
            return .failed(message:
                "No authenticated stale-daemon session is available for safe preparation."
            )
        }
        return await withCheckedContinuation { continuation in
            connection.prepareForUpgrade { result in
                connection.invalidate()
                switch result {
                case .success(let baseline):
                    continuation.resume(returning: .prepared(
                        sleepDisabledBaseline: baseline
                    ))
                case .failure(let error):
                    continuation.resume(returning: .failed(
                        message: error.localizedDescription
                    ))
                }
            }
        }
    }

    private func storePreparableConnection(_ connection: DaemonConnection) {
        lock.lock()
        let replaced = preparableConnection
        preparableConnection = connection
        lock.unlock()
        replaced?.invalidate()
    }

    private func takePreparableConnection() -> DaemonConnection? {
        lock.lock()
        let connection = preparableConnection
        preparableConnection = nil
        lock.unlock()
        return connection
    }

    private static func map(
        _ error: Error,
        expected: LetItBrewDaemonBuildIdentity
    ) -> DaemonHandshakeResult {
        guard let failure = error as? DaemonConnectionFailure else {
            return .failed(message: error.localizedDescription)
        }
        switch failure {
        case .staleBuild(_, let received):
            return .responded(DaemonHandshakeEvidence(
                protocolVersion: LetItBrewDaemonProtocolVersion.current,
                daemonBuild: received.codeDirectoryHash,
                reconciliation: .healthy
            ))
        case .incompatibleVersion(_, let received):
            return .responded(DaemonHandshakeEvidence(
                protocolVersion: received,
                daemonBuild: expected.codeDirectoryHash,
                reconciliation: .healthy
            ))
        case .reconciliationBlocked(let message):
            return .responded(DaemonHandshakeEvidence(
                protocolVersion: LetItBrewDaemonProtocolVersion.current,
                daemonBuild: expected.codeDirectoryHash,
                reconciliation: .blocked(message: message)
            ))
        case .legacyOrUnidentified(let received):
            return .responded(DaemonHandshakeEvidence(
                protocolVersion: received ?? LetItBrewDaemonProtocolVersion.current,
                daemonBuild: "legacy-unidentified",
                reconciliation: .blocked(message:
                    "The running legacy service cannot prove that its prior power state is reconciled. Use Let It Brew’s supported upgrade workflow before replacing it."
                )
            ))
        case .handshakeTimedOut:
            return .timedOut
        default:
            return .failed(message: failure.localizedDescription)
        }
    }
}

struct LiveDaemonServiceController: DaemonServiceControlling {
    private static let approvalInstructions =
        "Open System Settings → General → Login Items & Extensions. "
        + "Under App Background Activity, turn on Let It Brew. "
        + "macOS may ask for an administrator password or Touch ID. "
        + "Return to Let It Brew when you’re done; it will check automatically."

    func stopServiceForRefresh() async -> DaemonServiceOperationResult {
        do {
            try await DaemonRegistration.unregisterAndWait()
            return .succeeded
        } catch {
            switch DaemonRegistration.disposition(of: error) {
            case .alreadyUnregistered:
                return .succeeded
            case .approvalRequired:
                return .approvalRequired(message: Self.approvalInstructions)
            case .alreadyRegistered, .other:
                return Self.failure(error)
            }
        }
    }

    func startService() async -> DaemonServiceOperationResult {
        do {
            try DaemonRegistration.register()
            return .succeeded
        } catch {
            switch DaemonRegistration.disposition(of: error) {
            case .alreadyRegistered:
                // Verification still requires the exact bounded handshake;
                // this only treats the requested registration postcondition
                // as already satisfied.
                return .succeeded
            case .approvalRequired:
                return .approvalRequired(message: Self.approvalInstructions)
            case .alreadyUnregistered, .other:
                return Self.failure(error)
            }
        }
    }

    private static func failure(_ error: Error) -> DaemonServiceOperationResult {
        if case DaemonRegistrationFailure.ineligibleLocation = error {
            return .ineligible(message: error.localizedDescription)
        }
        if case DaemonRegistrationFailure.invalidSigningIdentity = error {
            return .ineligible(message: error.localizedDescription)
        }
        return .failed(message: error.localizedDescription)
    }
}

enum LiveDaemonRecoveryContext {
    static func make(closedLidEnabled: Bool) throws -> DaemonRecoveryContext {
        let build = try DaemonConnection.expectedBuildIdentity()
        let identity = DaemonRecoveryIdentity(
            protocolVersion: LetItBrewDaemonProtocolVersion.current,
            appBuild: build.versionDescription,
            daemonBuild: build.codeDirectoryHash
        )
        let mayManage = BackgroundServiceEligibility.mayManageBackgroundServices(
            bundleURL: Bundle.main.bundleURL,
            bundleIdentifier: Bundle.main.bundleIdentifier,
            signingIdentity: try RuntimeSigningIdentity.validatedCurrent()
        )
        return DaemonRecoveryContext(
            expectedIdentity: identity,
            closedLidEnabled: closedLidEnabled,
            mayManageService: mayManage
        )
    }
}

/// A reconciliation refusal, carried as a message the uninstall flow shows the
/// user. A dedicated type rather than `String` so no retroactive stdlib
/// conformance is needed.
struct DaemonUninstallPreparationFailure: Error {
    let message: String
}

/// The three-way outcome uninstall's `reconcileDaemon` gate needs.
/// `.absent` and `.failed` are both a `connect()` failure, and they must be
/// told apart: `.absent` lets uninstall proceed (there is no service to
/// reconcile), `.failed` blocks it (a service exists and would be abandoned
/// mid-debt). See `LiveDaemonUninstallPreparer.reconcile()` for exactly which
/// `DaemonConnectionFailure` cases land in each.
enum DaemonUninstallReconciliationOutcome {
    case reconciled(
        sleepDisabledBaseline: Bool,
        buildIdentity: LetItBrewDaemonBuildIdentity
    )
    case absent
    case failed(DaemonUninstallPreparationFailure)
}

/// Forces the healthy daemon to reconcile any owed `disablesleep` restore
/// before uninstall removes the app. Success is what causes the root-owned
/// `sleep-debt.json` to delete itself, which is why uninstall needs no admin
/// prompt. A fresh connection is required: `prepareForUpgrade` is authorized
/// by this handshake, and `DaemonConnection` handshakes exactly once.
enum LiveDaemonUninstallPreparer {
    static func reconcile() async -> DaemonUninstallReconciliationOutcome {
        let connection: DaemonConnection
        do {
            connection = try DaemonConnection()
        } catch {
            // A certificate-free development build cannot authenticate a
            // daemon, but that must not strand one-click uninstall when no
            // service exists. Probe only the two product-owned service names
            // without a signing requirement. Structured 4099 is affirmative
            // absence; every other result still blocks.
            if let identifier = Bundle.main.bundleIdentifier,
               [
                   BackgroundServiceEligibility.productionAppIdentifier,
                   BackgroundServiceEligibility.developmentAppIdentifier,
               ].contains(identifier) {
                let probe: Result<Void, Error> = await withCheckedContinuation {
                    continuation in
                    DaemonConnection.probeServiceTransport(
                        machServiceName: identifier + ".daemon"
                    ) { continuation.resume(returning: $0) }
                }
                if case .failure(let probeError) = probe,
                   let failure = probeError as? DaemonConnectionFailure,
                   case .transportUnreachable(let domain, let code, _) = failure,
                   DaemonConnectionAbsenceClassifier.classify(
                       domain: domain,
                       code: code
                   ) == .affirmativelyAbsent {
                    return .absent
                }
            }
            return .failed(DaemonUninstallPreparationFailure(
                message: error.localizedDescription
            ))
        }

        let handshake: Result<LetItBrewDaemonBuildIdentity, Error> =
            await withCheckedContinuation { continuation in
                connection.connect { continuation.resume(returning: $0) }
            }
        if case .failure(let error) = handshake {
            connection.invalidate()
            // A `.transportUnreachable` from this FIRST connect attempt is
            // ambiguous by construction — "I could not reach it" is not
            // evidence of absence, because a registered daemon that crashed,
            // was rejected during XPC authentication, or dropped the
            // connection before replying looks identical from here unless we
            // inspect the underlying transport error. Only
            // `DaemonConnectionAbsenceClassifier` reading `domain`/`code` can
            // tell "no such service" apart from "a live service reached us
            // and then failed" — see its doc comment for the empirical
            // evidence. Every other `DaemonConnectionFailure` case here
            // (incompatibleVersion, legacyOrUnidentified, staleBuild,
            // reconciliationBlocked, handshakeTimedOut, the local
            // `.unavailable` "Invalid XPC interface." cast failure, ...)
            // requires a live process to have actually accepted the
            // connection and taken part in the handshake, or proves nothing
            // about the service either way — both must block.
            if let failure = error as? DaemonConnectionFailure,
               case .transportUnreachable(let domain, let code, _) = failure,
               DaemonConnectionAbsenceClassifier.classify(domain: domain, code: code)
                   == .affirmativelyAbsent {
                return .absent
            }
            return .failed(DaemonUninstallPreparationFailure(
                message: error.localizedDescription
            ))
        }
        guard case .success(let buildIdentity) = handshake else {
            return .failed(DaemonUninstallPreparationFailure(
                message: "The daemon handshake returned no build identity."
            ))
        }

        // We only reach here after a successful handshake, i.e. a live
        // daemon just proved it exists. Any failure from this point on
        // (including a fresh `.unavailable` if it drops the connection
        // mid-preparation) is that proven daemon refusing or disappearing
        // mid-operation, never "absent" — it must block.
        return await withCheckedContinuation { continuation in
            connection.prepareForUpgrade { result in
                connection.invalidate()
                switch result {
                case .success(let baseline):
                    continuation.resume(returning: .reconciled(
                        sleepDisabledBaseline: baseline,
                        buildIdentity: buildIdentity
                    ))
                case .failure(let error):
                    continuation.resume(returning: .failed(
                        DaemonUninstallPreparationFailure(
                            message: error.localizedDescription
                        )
                    ))
                }
            }
        }
    }
}
