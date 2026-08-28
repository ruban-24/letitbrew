/// The exact app/daemon pair whose health Let It Brew is trying to establish.
///
/// The strings are deliberately opaque to AppCore. The application integration
/// may use a signed build manifest or code-directory hashes without coupling the
/// recovery policy to Security.framework.
public struct DaemonRecoveryIdentity: Codable, Equatable, Hashable, Sendable {
    public let protocolVersion: Int
    public let appBuild: String
    public let daemonBuild: String

    public init(
        protocolVersion: Int,
        appBuild: String,
        daemonBuild: String
    ) {
        self.protocolVersion = protocolVersion
        self.appBuild = appBuild
        self.daemonBuild = daemonBuild
    }
}

public enum DaemonReconciliationHealth: Equatable, Sendable {
    case healthy
    case blocked(message: String)
}

/// Authenticated evidence returned by the daemon. Authentication itself stays
/// in the application/XPC adapter; this value carries only the evidence the
/// pure policy must compare.
public struct DaemonHandshakeEvidence: Equatable, Sendable {
    public let protocolVersion: Int
    public let daemonBuild: String
    public let reconciliation: DaemonReconciliationHealth

    public init(
        protocolVersion: Int,
        daemonBuild: String,
        reconciliation: DaemonReconciliationHealth
    ) {
        self.protocolVersion = protocolVersion
        self.daemonBuild = daemonBuild
        self.reconciliation = reconciliation
    }
}

/// `approvalRequired` must be returned only when the live adapter has positive
/// evidence that macOS approval is the blocker. A generic XPC failure belongs
/// in `failed`, never in `approvalRequired`.
public enum DaemonHandshakeResult: Equatable, Sendable {
    case responded(DaemonHandshakeEvidence)
    case approvalRequired(message: String)
    case failed(message: String)
    case timedOut
}

public struct DaemonRecoveryPersistenceSnapshot: Equatable, Sendable {
    public let lastHealthyIdentity: DaemonRecoveryIdentity?
    public let automaticRefreshAttemptIdentity: DaemonRecoveryIdentity?

    public init(
        lastHealthyIdentity: DaemonRecoveryIdentity?,
        automaticRefreshAttemptIdentity: DaemonRecoveryIdentity?
    ) {
        self.lastHealthyIdentity = lastHealthyIdentity
        self.automaticRefreshAttemptIdentity = automaticRefreshAttemptIdentity
    }
}

public enum DaemonRecoveryPersistenceLoadResult: Equatable, Sendable {
    case loaded(DaemonRecoveryPersistenceSnapshot)
    case failed(message: String)
}

public enum DaemonRecoveryPersistenceWriteResult: Equatable, Sendable {
    case succeeded
    case failed(message: String)
}

/// Result of asking the already-authenticated stale daemon session to reconcile
/// its debt, return the exact live baseline, and reject every later acquisition
/// until that daemon exits.
public enum DaemonRecoveryPreparationResult: Equatable, Sendable {
    case prepared(sleepDisabledBaseline: Bool)
    case failed(message: String)
}

public enum DaemonServiceOperationResult: Equatable, Sendable {
    case succeeded
    case approvalRequired(message: String)
    case failed(message: String)
    case ineligible(message: String)
}

public enum DaemonRecoveryTrigger: Equatable, Sendable {
    /// Ordinary launch. This is the only trigger constrained by the durable
    /// one-automatic-refresh-per-identity guard.
    case automaticLaunch

    /// An explicit retry after a previously surfaced failure.
    case userRequestedRetry

    /// First-install setup explicitly requested by the user. A missing service
    /// is started directly; an authenticated stale responder is refreshed.
    case userRequestedSetup
}

public enum DaemonRecoveryFailure: Equatable, Sendable {
    case explicitSetupRequired(message: String)
    case automaticRefreshAlreadyAttempted(message: String)
    case handshakeFailed(message: String)
    case handshakeTimedOut
    case incompatibleProtocol(expected: Int, received: Int)
    case unexpectedDaemonBuild(expected: String, received: String)
    case reconciliationBlocked(message: String)
    case upgradePreparationFailed(message: String)
    case serviceStopFailed(message: String)
    case serviceStartFailed(message: String)
    case persistenceFailed(message: String)

    public var diagnosticMessage: String {
        switch self {
        case .explicitSetupRequired(let message),
             .automaticRefreshAlreadyAttempted(let message),
             .handshakeFailed(let message),
             .reconciliationBlocked(let message),
             .upgradePreparationFailed(let message),
             .serviceStopFailed(let message),
             .serviceStartFailed(let message),
             .persistenceFailed(let message):
            message
        case .handshakeTimedOut:
            "The closed-lid support check timed out."
        case .incompatibleProtocol(let expected, let received):
            "The running service uses protocol v\(received); this app requires v\(expected)."
        case .unexpectedDaemonBuild(let expected, let received):
            "The running service build '\(received)' does not match the installed build '\(expected)'."
        }
    }
}

public enum DaemonRecoveryState: Equatable, Sendable {
    case checking
    case finishingUpdate
    case restartingSupport
    case ready
    case approvalRequired(message: String)
    case retryableFailure(DaemonRecoveryFailure)
    case ineligible(message: String)

    /// The explicit closed-lid-off preference suppresses automatic service
    /// mutation and setup attention until the user enables the feature again.
    case deferredUntilEnabled
}

public enum DaemonRecoveryUserAction: Equatable, Sendable {
    case retry
    case setUp
    case openBackgroundItems
}

/// Copy and actions are derived solely from state, preventing the UI from
/// turning every unavailable daemon into generic setup or Background Items
/// guidance.
public struct DaemonRecoveryPresentation: Equatable, Sendable {
    public let headline: String
    public let detail: String?
    public let actions: [DaemonRecoveryUserAction]
    public let showsProgress: Bool
    public let requiresAttention: Bool

    public init(state: DaemonRecoveryState) {
        switch state {
        case .checking:
            headline = "Checking closed-lid support…"
            detail = nil
            actions = []
            showsProgress = true
            requiresAttention = false
        case .finishingUpdate:
            headline = "Finishing update…"
            detail = nil
            actions = []
            showsProgress = true
            requiresAttention = false
        case .restartingSupport:
            headline = "Restarting closed-lid support…"
            detail = nil
            actions = []
            showsProgress = true
            requiresAttention = false
        case .ready:
            headline = "Closed-lid support is ready."
            detail = nil
            actions = []
            showsProgress = false
            requiresAttention = false
        case .approvalRequired(let message):
            headline = "Closed-lid support needs approval"
            detail = message
            actions = [.openBackgroundItems]
            showsProgress = false
            requiresAttention = true
        case .retryableFailure(let failure):
            switch failure {
            case .explicitSetupRequired:
                headline = "Closed-lid support isn’t set up."
                actions = [.setUp]
            default:
                headline = "Closed-lid support couldn’t restart."
                actions = [.retry]
            }
            detail = failure.diagnosticMessage
            showsProgress = false
            requiresAttention = true
        case .ineligible(let message):
            headline = "Closed-lid support is unavailable from this copy."
            detail = message
            actions = []
            showsProgress = false
            requiresAttention = true
        case .deferredUntilEnabled:
            headline = "Closed-lid support is off."
            detail = "Its service update will resume only if you enable closed-lid support."
            actions = []
            showsProgress = false
            requiresAttention = false
        }
    }
}

public struct BackgroundHelperPresentation: Equatable, Sendable {
    public let status: String
    public let detail: String
    public let actions: [DaemonRecoveryUserAction]
    public let showsProgress: Bool
    public let requiresAttention: Bool

    public init(
        status: String,
        detail: String,
        actions: [DaemonRecoveryUserAction],
        showsProgress: Bool,
        requiresAttention: Bool
    ) {
        self.status = status
        self.detail = detail
        self.actions = actions
        self.showsProgress = showsProgress
        self.requiresAttention = requiresAttention
    }
}

public enum BackgroundHelperPresentationPolicy {
    public static func resolve(
        closedLidEnabled: Bool,
        recoveryState: DaemonRecoveryState
    ) -> BackgroundHelperPresentation {
        guard closedLidEnabled else {
            return BackgroundHelperPresentation(
                status: "Not in use",
                detail: "Closed-lid support is disabled.",
                actions: [],
                showsProgress: false,
                requiresAttention: false
            )
        }

        let recovery = DaemonRecoveryPresentation(state: recoveryState)
        let status: String = switch recoveryState {
        case .checking:
            "Checking"
        case .finishingUpdate, .restartingSupport:
            "Repairing"
        case .ready:
            "Running normally"
        case .approvalRequired, .retryableFailure, .ineligible:
            "Needs attention"
        case .deferredUntilEnabled:
            "Not in use"
        }
        return BackgroundHelperPresentation(
            status: status,
            detail: recovery.detail ?? recovery.headline,
            actions: recovery.actions,
            showsProgress: recovery.showsProgress,
            requiresAttention: recovery.requiresAttention
        )
    }
}

public enum DaemonRecoveryPolicyDecision: Equatable, Sendable {
    case acceptHealthy
    case requestAutomaticRefresh
    case requestExplicitRefresh
    case requestExplicitSetup
    case deferUntilEnabled
    case approvalRequired(message: String)
    case fail(DaemonRecoveryFailure)
}

public enum DaemonRecoveryPolicy {
    public static func decide(
        expected: DaemonRecoveryIdentity,
        closedLidEnabled: Bool,
        trigger: DaemonRecoveryTrigger,
        persistence: DaemonRecoveryPersistenceSnapshot,
        handshake: DaemonHandshakeResult
    ) -> DaemonRecoveryPolicyDecision {
        if case .responded(let evidence) = handshake,
           evidence.protocolVersion == expected.protocolVersion,
           evidence.daemonBuild == expected.daemonBuild,
           evidence.reconciliation == .healthy {
            return .acceptHealthy
        }

        guard closedLidEnabled else {
            return .deferUntilEnabled
        }

        if case .approvalRequired(let message) = handshake {
            return .approvalRequired(message: message)
        }

        // An authenticated daemon with unresolved restore debt must remain in
        // place so it can retry reconciliation. Stopping it for any automatic
        // or explicit refresh would abandon the only component that can prove
        // and complete the prior SleepDisabled restoration.
        if case .responded(let evidence) = handshake,
           case .blocked(let message) = evidence.reconciliation {
            return .fail(.reconciliationBlocked(message: message))
        }

        let mayRefresh = isAuthenticatedRefreshCandidate(
            handshake,
            expected: expected
        )

        switch trigger {
        case .userRequestedSetup:
            if mayRefresh {
                return .requestExplicitRefresh
            }
            if case .responded = handshake {
                return .fail(failure(for: handshake, expected: expected))
            }
            return .requestExplicitSetup
        case .userRequestedRetry:
            if mayRefresh {
                return .requestExplicitRefresh
            }
            if case .responded = handshake {
                return .fail(failure(for: handshake, expected: expected))
            }
            return .requestExplicitSetup
        case .automaticLaunch:
            guard let lastHealthy = persistence.lastHealthyIdentity else {
                return .fail(.explicitSetupRequired(
                    message: "Choose Set Up to enable closed-lid support on this Mac."
                ))
            }
            guard lastHealthy != expected else {
                return .fail(failure(for: handshake, expected: expected))
            }
            guard mayRefresh else {
                return .fail(failure(for: handshake, expected: expected))
            }
            guard persistence.automaticRefreshAttemptIdentity != expected else {
                return .fail(.automaticRefreshAlreadyAttempted(
                    message: "Automatic recovery was already attempted for this build. Choose Retry to try again."
                ))
            }
            return .requestAutomaticRefresh
        }
    }

    /// Service replacement is permitted only after a positive authenticated
    /// same-protocol reply from an older exact daemon image. Generic failure,
    /// timeout, protocol mismatch, legacy identity, and blocked reconciliation
    /// are deliberately non-refreshable.
    private static func isAuthenticatedRefreshCandidate(
        _ handshake: DaemonHandshakeResult,
        expected: DaemonRecoveryIdentity
    ) -> Bool {
        guard case .responded(let evidence) = handshake,
              evidence.protocolVersion == expected.protocolVersion,
              evidence.daemonBuild != expected.daemonBuild,
              evidence.reconciliation == .healthy
        else {
            return false
        }
        return true
    }

    public static func failure(
        for handshake: DaemonHandshakeResult,
        expected: DaemonRecoveryIdentity
    ) -> DaemonRecoveryFailure {
        switch handshake {
        case .responded(let evidence):
            if evidence.protocolVersion != expected.protocolVersion {
                return .incompatibleProtocol(
                    expected: expected.protocolVersion,
                    received: evidence.protocolVersion
                )
            }
            if evidence.daemonBuild != expected.daemonBuild {
                return .unexpectedDaemonBuild(
                    expected: expected.daemonBuild,
                    received: evidence.daemonBuild
                )
            }
            if case .blocked(let message) = evidence.reconciliation {
                return .reconciliationBlocked(message: message)
            }
            return .handshakeFailed(message: "The daemon handshake was incomplete.")
        case .approvalRequired(let message):
            return .handshakeFailed(message: message)
        case .failed(let message):
            return .handshakeFailed(message: message)
        case .timedOut:
            return .handshakeTimedOut
        }
    }
}
