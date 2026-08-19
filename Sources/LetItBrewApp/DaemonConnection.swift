import Foundation
import LetItBrewDaemonCore

enum DaemonConnectionFailure: LocalizedError {
    case unsignedApp
    case invalidAppIdentifier
    case invalidEmbeddedDaemon(String)
    case unavailable(String)
    /// The very first proxy call of `connect()` never reached any XPC peer.
    /// Unlike `.unavailable`, this preserves the underlying `NSError`'s
    /// `domain`/`code` — not just its free-form description — because a
    /// caller may need to tell "no such service" apart from "a live service
    /// rejected or dropped us", and only the structured domain/code can do
    /// that reliably. See `DaemonConnectionAbsenceClassifier` in
    /// LetItBrewAppCore for how `reconcileDaemon()`'s uninstall gate uses it.
    case transportUnreachable(domain: String, code: Int, message: String)
    case incompatibleVersion(expected: Int, received: Int)
    case legacyOrUnidentified(receivedProtocol: Int?)
    case staleBuild(
        expected: LetItBrewDaemonBuildIdentity,
        received: LetItBrewDaemonBuildIdentity
    )
    case reconciliationBlocked(String)
    case handshakeTimedOut
    case handshakeAlreadyStarted
    case handshakeRequired
    case upgradePreparationFailed(String)
    case invalidUpgradeBaseline(Int)

    var errorDescription: String? {
        switch self {
        case .unsignedApp:
            "Let It Brew's Apple signing identity could not be read."
        case .invalidAppIdentifier:
            "Let It Brew's daemon identifier could not be derived from the app signature."
        case .invalidEmbeddedDaemon(let message):
            "Let It Brew's embedded daemon could not be verified: \(message)"
        case .unavailable(let message):
            "The privileged daemon is unavailable: \(message)"
        case .transportUnreachable(_, _, let message):
            "The privileged daemon is unavailable: \(message)"
        case .incompatibleVersion(let expected, let received):
            "The privileged daemon uses protocol v\(received); this app requires v\(expected)."
        case .legacyOrUnidentified(let receivedProtocol):
            if let receivedProtocol {
                "The running protocol-v\(receivedProtocol) daemon does not identify its exact build."
            } else {
                "The running daemon does not identify its exact build."
            }
        case .staleBuild(let expected, let received):
            "The running daemon is \(received.versionDescription) [\(received.codeDirectoryHash)]; this app contains \(expected.versionDescription) [\(expected.codeDirectoryHash)]."
        case .reconciliationBlocked(let message):
            "The privileged daemon could not reconcile its prior power state: \(message)"
        case .handshakeTimedOut:
            "The privileged daemon handshake timed out."
        case .handshakeAlreadyStarted:
            "The privileged daemon handshake was already started."
        case .handshakeRequired:
            "The privileged daemon handshake has not completed."
        case .upgradePreparationFailed(let message):
            "The privileged daemon refused upgrade preparation: \(message)"
        case .invalidUpgradeBaseline(let value):
            "The privileged daemon returned an invalid SleepDisabled baseline (\(value))."
        }
    }
}

private final class DaemonCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func runOnce(_ operation: () -> Void) {
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        lock.unlock()
        operation()
    }
}

/// Owns the unauthenticated transport probe across its asynchronous XPC
/// callbacks. The one-shot gate serializes completion, and invalidation drops
/// the handler cycle after the first response, error, interruption, or timeout.
private final class DaemonServiceTransportProbe: @unchecked Sendable {
    private let connection: NSXPCConnection
    private let gate = DaemonCompletionGate()
    private let timeout: TimeInterval
    private let completion: @Sendable (Result<Void, Error>) -> Void

    init(
        machServiceName: String,
        timeout: TimeInterval,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        connection = NSXPCConnection(
            machServiceName: machServiceName,
            options: .privileged
        )
        self.timeout = timeout
        self.completion = completion
    }

    func start() {
        connection.remoteObjectInterface = NSXPCInterface(
            with: LetItBrewDaemonXPCProtocol.self
        )
        connection.interruptionHandler = { [self] in
            finish(.failure(DaemonConnectionFailure.transportUnreachable(
                domain: NSCocoaErrorDomain,
                code: NSXPCConnectionInterrupted,
                message: "The background service interrupted the presence check."
            )))
        }
        connection.resume()

        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [self] error in
            let underlying = error as NSError
            finish(.failure(DaemonConnectionFailure.transportUnreachable(
                domain: underlying.domain,
                code: underlying.code,
                message: underlying.localizedDescription
            )))
        }) as? LetItBrewDaemonXPCProtocol else {
            finish(.failure(DaemonConnectionFailure.unavailable(
                "Invalid XPC interface during the presence check."
            )))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + max(0.1, timeout)
        ) { [self] in
            finish(.failure(DaemonConnectionFailure.handshakeTimedOut))
        }
        proxy.protocolVersion { [self] _ in finish(.success(())) }
    }

    private func finish(_ result: Result<Void, Error>) {
        gate.runOnce {
            connection.interruptionHandler = nil
            connection.invalidate()
            completion(result)
        }
    }
}

/// A mutually authenticated client for the privileged launch daemon.
/// Constructing this object creates only an XPC connection; it never creates,
/// registers, or queries an `SMAppService`.
final class DaemonConnection: @unchecked Sendable {
    typealias Completion = @Sendable (Result<Void, Error>) -> Void
    typealias HandshakeCompletion = @Sendable (
        Result<LetItBrewDaemonBuildIdentity, Error>
    ) -> Void
    typealias UpgradePreparationCompletion = @Sendable (Result<Bool, Error>) -> Void

    private let lock = NSLock()
    private let connection: NSXPCConnection
    private let expectedBuild: LetItBrewDaemonBuildIdentity
    private var compatible = false
    private var upgradePreparationAuthorized = false
    private var connectStarted = false

    init() throws {
        let identities = try Self.validatedIdentities()
        let daemonIdentity = identities.daemon

        let connection = NSXPCConnection(
            machServiceName: daemonIdentity.identifier,
            options: .privileged
        )
        connection.remoteObjectInterface = NSXPCInterface(
            with: LetItBrewDaemonXPCProtocol.self
        )
        connection.setCodeSigningRequirement(daemonIdentity.codeSigningRequirement)
        self.connection = connection
        expectedBuild = identities.expectedBuild
        connection.interruptionHandler = { [weak self] in
            self?.clearAuthorization()
        }
        connection.invalidationHandler = { [weak self] in
            self?.clearAuthorization()
        }
    }

    static func expectedBuildIdentity() throws -> LetItBrewDaemonBuildIdentity {
        try validatedIdentities().expectedBuild
    }

    var expectedBuildIdentity: LetItBrewDaemonBuildIdentity {
        expectedBuild
    }

    /// A read-only fallback for a copy whose own signature cannot construct
    /// an authenticated connection. It may prove only that a known launchd
    /// service is absent. Any peer response, authentication interruption,
    /// timeout, or unfamiliar transport error remains a refusal.
    static func probeServiceTransport(
        machServiceName: String,
        timeout: TimeInterval = 1,
        completion: @escaping Completion
    ) {
        DaemonServiceTransportProbe(
            machServiceName: machServiceName,
            timeout: timeout,
            completion: completion
        ).start()
    }

    private static func validatedIdentities() throws -> (
        daemon: RuntimeSigningIdentity,
        expectedBuild: LetItBrewDaemonBuildIdentity
    ) {
        let appIdentity: RuntimeSigningIdentity
        do {
            appIdentity = try RuntimeSigningIdentity.validatedCurrent()
        } catch {
            throw DaemonConnectionFailure.unavailable(error.localizedDescription)
        }
        let daemonIdentity = RuntimeSigningIdentity(
            identifier: appIdentity.identifier + ".daemon",
            teamIdentifier: appIdentity.teamIdentifier
        )
        guard daemonIdentity.appClientIdentity() == appIdentity else {
            throw DaemonConnectionFailure.invalidAppIdentifier
        }

        let daemonURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchServices/LetItBrewDaemon",
            isDirectory: false
        )
        let embeddedCode: RuntimeSignedCodeIdentity
        do {
            embeddedCode = try RuntimeSigningIdentity.validatedCode(
                executableURL: daemonURL
            )
        } catch {
            throw DaemonConnectionFailure.invalidEmbeddedDaemon(
                error.localizedDescription
            )
        }
        guard embeddedCode.signingIdentity.identifier == daemonIdentity.identifier,
              embeddedCode.signingIdentity.teamIdentifier == daemonIdentity.teamIdentifier,
              let expectedBuild = LetItBrewDaemonBuildIdentity(
                marketingVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String,
                buildVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String,
                codeDirectoryHash: embeddedCode.codeDirectoryHash
              )
        else {
            throw DaemonConnectionFailure.invalidEmbeddedDaemon(
                "Its identifier, Team ID, version, build, or Code Directory hash does not match the app."
            )
        }

        return (daemonIdentity, expectedBuild)
    }

    func connect(
        timeout: TimeInterval = 5,
        completion: @escaping HandshakeCompletion
    ) {
        guard withLock({
            guard !connectStarted else { return false }
            connectStarted = true
            return true
        }) else {
            completion(.failure(DaemonConnectionFailure.handshakeAlreadyStarted))
            return
        }

        let gate = DaemonCompletionGate()
        let finish: @Sendable (Result<LetItBrewDaemonBuildIdentity, Error>) -> Void = {
            [weak self] result in
            gate.runOnce {
                let succeeded: Bool
                if case .success = result { succeeded = true } else { succeeded = false }
                let mayPrepareStale = Self.isAuthenticatedStaleBuild(result)
                self?.withLock {
                    self?.compatible = succeeded
                    self?.upgradePreparationAuthorized = succeeded || mayPrepareStale
                }
                // A same-protocol stale-build result was received only after the
                // daemon passed the connection signing requirement and returned
                // its complete additive handshake with healthy reconciliation.
                // Keep exactly that session alive so recovery can quiesce it.
                if !succeeded && !mayPrepareStale {
                    self?.connection.invalidate()
                }
                completion(result)
            }
        }

        connection.resume()
        guard let versionProxy = proxy(errorHandler: { error in
            let underlying = error as NSError
            finish(.failure(DaemonConnectionFailure.transportUnreachable(
                domain: underlying.domain,
                code: underlying.code,
                message: underlying.localizedDescription
            )))
        }) else {
            finish(.failure(DaemonConnectionFailure.unavailable("Invalid XPC interface.")))
            return
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + max(0.1, timeout)
        ) {
            finish(.failure(DaemonConnectionFailure.handshakeTimedOut))
        }

        // Protocol v1 predates the exact-build selector. Ask the original v1
        // method first so a daemon that authenticates but lacks the additive
        // handshake is reported as legacy instead of generic setup failure.
        versionProxy.protocolVersion { [weak self, expectedBuild] protocolVersion in
            guard protocolVersion == LetItBrewDaemonProtocolVersion.current else {
                finish(.failure(DaemonConnectionFailure.incompatibleVersion(
                    expected: LetItBrewDaemonProtocolVersion.current,
                    received: protocolVersion
                )))
                return
            }
            guard let self,
                  let handshakeProxy = self.proxy(errorHandler: { _ in
                      finish(.failure(DaemonConnectionFailure.legacyOrUnidentified(
                          receivedProtocol: protocolVersion
                      )))
                  })
            else {
                finish(.failure(DaemonConnectionFailure.legacyOrUnidentified(
                    receivedProtocol: protocolVersion
                )))
                return
            }

            handshakeProxy.daemonHandshake {
                protocolVersion,
                marketingVersion,
                buildVersion,
                codeDirectoryHash,
                reconciliationReady,
                reconciliationMessage in
                let compatibility = LetItBrewDaemonHandshakeCompatibility.evaluate(
                    expectedBuild: expectedBuild,
                    receivedProtocol: protocolVersion,
                    receivedMarketingVersion: marketingVersion,
                    receivedBuildVersion: buildVersion,
                    receivedCodeDirectoryHash: codeDirectoryHash,
                    reconciliationReady: reconciliationReady,
                    reconciliationMessage: reconciliationMessage
                )
                switch compatibility {
                case .compatible:
                    finish(.success(expectedBuild))
                case .reconciliationBlocked(let message):
                    finish(.failure(DaemonConnectionFailure.reconciliationBlocked(message)))
                case .incompatibleProtocol(let expected, let received):
                    finish(.failure(DaemonConnectionFailure.incompatibleVersion(
                        expected: expected,
                        received: received
                    )))
                case .legacyOrUnidentified(let receivedProtocol):
                    finish(.failure(DaemonConnectionFailure.legacyOrUnidentified(
                        receivedProtocol: receivedProtocol
                    )))
                case .staleBuild(let expected, let received):
                    finish(.failure(DaemonConnectionFailure.staleBuild(
                        expected: expected,
                        received: received
                    )))
                }
            }
        }
    }

    func prepareForUpgrade(
        timeout: TimeInterval = 5,
        completion: @escaping UpgradePreparationCompletion
    ) {
        guard withLock({ upgradePreparationAuthorized }) else {
            completion(.failure(DaemonConnectionFailure.handshakeRequired))
            return
        }
        let gate = DaemonCompletionGate()
        let finish: @Sendable (Result<Bool, Error>) -> Void = { result in
            gate.runOnce { completion(result) }
        }
        guard let proxy = proxy(errorHandler: { error in
            finish(.failure(DaemonConnectionFailure.unavailable(
                error.localizedDescription
            )))
        }) else {
            finish(.failure(DaemonConnectionFailure.unavailable(
                "Invalid XPC interface."
            )))
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + max(0.1, timeout)
        ) {
            finish(.failure(DaemonConnectionFailure.handshakeTimedOut))
        }
        proxy.prepareForUpgrade { succeeded, message, baseline in
            guard succeeded else {
                finish(.failure(DaemonConnectionFailure.upgradePreparationFailed(
                    message ?? "No reason was provided."
                )))
                return
            }
            guard baseline == 0 || baseline == 1 else {
                finish(.failure(DaemonConnectionFailure.invalidUpgradeBaseline(
                    baseline
                )))
                return
            }
            finish(.success(baseline == 1))
        }
    }

    func setLidClosedHold(_ enabled: Bool, completion: @escaping Completion) {
        guard withLock({ compatible }) else {
            completion(.failure(DaemonConnectionFailure.handshakeRequired))
            return
        }
        guard let proxy = proxy(errorHandler: { error in
            completion(.failure(DaemonConnectionFailure.unavailable(error.localizedDescription)))
        }) else {
            completion(.failure(DaemonConnectionFailure.unavailable("Invalid XPC interface.")))
            return
        }

        proxy.setLidClosedHold(enabled) { succeeded, message in
            if succeeded {
                completion(.success(()))
            } else {
                completion(.failure(DaemonConnectionFailure.unavailable(
                    message ?? "The daemon refused the hold."
                )))
            }
        }
    }

    func invalidate() {
        connection.invalidate()
    }

    private func proxy(
        errorHandler: @escaping @Sendable (Error) -> Void
    ) -> LetItBrewDaemonXPCProtocol? {
        connection.remoteObjectProxyWithErrorHandler(errorHandler)
            as? LetItBrewDaemonXPCProtocol
    }

    private static func isAuthenticatedStaleBuild(
        _ result: Result<LetItBrewDaemonBuildIdentity, Error>
    ) -> Bool {
        guard case .failure(let error) = result,
              let failure = error as? DaemonConnectionFailure,
              case .staleBuild = failure
        else {
            return false
        }
        return true
    }

    private func clearAuthorization() {
        withLock {
            compatible = false
            upgradePreparationAuthorized = false
        }
    }

    private func withLock<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }
}
