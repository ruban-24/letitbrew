import Foundation

/// Every distinct thing uninstall removes or proves. The raw value appears in
/// diagnostics the user can copy into a bug report.
public enum UninstallStep: String, CaseIterable, Equatable, Sendable {
    case releaseHolds
    case reconcileDaemon
    case unregisterDaemon
    case removeClaudeHooks
    case removeCodexHooks
    case removeCursorHooks
    case removeOpenCodeHooks
    case removeCopilotHooks
    case disableLaunchAtLogin
    case deleteUserData
    case clearPreferences
    case trashBundle

    /// A gate refuses the whole uninstall. Everything else is best-effort and
    /// is reported rather than blocking. The three gates are the steps whose
    /// failure could leave the Mac held awake or leave a registered launchd
    /// job with no app able to unregister it.
    public var isGate: Bool {
        switch self {
        case .releaseHolds, .reconcileDaemon, .unregisterDaemon:
            true
        case .removeClaudeHooks, .removeCodexHooks, .removeCursorHooks,
             .removeOpenCodeHooks, .removeCopilotHooks, .disableLaunchAtLogin,
             .deleteUserData, .clearPreferences, .trashBundle:
            false
        }
    }
}

public struct UninstallFailure: Error, Equatable, Sendable {
    public let step: UninstallStep
    /// One sentence shown directly to the user.
    public let message: String
    /// Detail for the copyable diagnostic. Never shown inline.
    public let diagnostic: String

    public init(step: UninstallStep, message: String, diagnostic: String) {
        self.step = step
        self.message = message
        self.diagnostic = diagnostic
    }
}

public enum UninstallState: Equatable, Sendable {
    case idle
    case awaitingConfirmation
    /// A gate refused. Nothing has been removed.
    case blocked(UninstallFailure, offersDiagnostic: Bool)
    /// Teardown finished with best-effort steps that failed. Never empty.
    case report(leftovers: [UninstallFailure])
    case finished
}

public enum UninstallDaemonReconciliation: Equatable, Sendable {
    case present
    case affirmativelyAbsent
}

/// The only path from the coordinator to the world. A fake conformance is what
/// makes the whole sequence testable without touching launchd or /Applications.
public protocol UninstallEnvironment: AnyObject, Sendable {
    func releaseHolds() async -> Result<Void, UninstallFailure>
    func reconcileDaemon() async -> Result<UninstallDaemonReconciliation, UninstallFailure>
    func unregisterDaemon() async -> Result<Void, UninstallFailure>
    func removeClaudeHooks() async -> Result<Void, UninstallFailure>
    func removeCodexHooks() async -> Result<Void, UninstallFailure>
    func removeCursorHooks() async -> Result<Void, UninstallFailure>
    func removeOpenCodeHooks() async -> Result<Void, UninstallFailure>
    func removeCopilotHooks() async -> Result<Void, UninstallFailure>
    func disableLaunchAtLogin() async -> Result<Void, UninstallFailure>
    func deleteUserData() async -> Result<Void, UninstallFailure>
    func clearPreferences() async -> Result<Void, UninstallFailure>
    func trashBundle() async -> Result<Void, UninstallFailure>
}

/// The single place uninstall sequencing exists, and therefore the single
/// place it can regress. Holds no I/O of its own.
@MainActor
public final class UninstallCoordinator {
    /// Gate failures are usually a daemon caught mid-operation, so one silent
    /// retry precedes any user-visible refusal.
    public static let automaticGateAttempts = 2

    public private(set) var state: UninstallState = .idle

    private let environment: any UninstallEnvironment
    private var userRetryCount = 0
    /// Set for the exact span `confirm()` is running the gates and removals.
    /// The UI hides confirmation as soon as its in-progress flag is set, but
    /// `cancel()` still guards the coordinator itself so no direct or delayed
    /// caller can set `state` to `.idle` while an already-entered `confirm()`
    /// resumes after an await and keeps removing things. Guarding once here
    /// covers every await inside `confirm()`.
    private var isTearingDown = false

    public init(environment: any UninstallEnvironment) {
        self.environment = environment
    }

    public func beginPrecheck() async {
        guard state == .idle else { return }
        await runPrecheck()
    }

    public func retryPrecheck() async {
        guard case .blocked = state else { return }
        userRetryCount += 1
        await runPrecheck()
    }

    public func cancel() {
        guard !isTearingDown else { return }
        state = .idle
    }

    /// Gates run again here rather than trusting the precheck: the user may
    /// have sat on the confirmation sheet while an agent started working, or
    /// resumed Let It Brew and reacquired a hold nothing else rechecks. All
    /// three hard gates precede every removal, so a refusal here has still
    /// removed nothing.
    public func confirm() async {
        guard state == .awaitingConfirmation else { return }
        isTearingDown = true
        defer { isTearingDown = false }

        if case .failure(let failure) = await environment.releaseHolds() {
            state = .blocked(failure, offersDiagnostic: true)
            return
        }
        let reconciliation: UninstallDaemonReconciliation
        switch await environment.reconcileDaemon() {
        case .success(let result):
            reconciliation = result
        case .failure(let failure):
            state = .blocked(failure, offersDiagnostic: true)
            return
        }
        if reconciliation == .present,
           case .failure(let failure) = await environment.unregisterDaemon() {
            state = .blocked(failure, offersDiagnostic: true)
            return
        }

        let bestEffort: [() async -> Result<Void, UninstallFailure>] = [
            environment.removeClaudeHooks,
            environment.removeCodexHooks,
            environment.removeCursorHooks,
            environment.removeOpenCodeHooks,
            environment.removeCopilotHooks,
            environment.disableLaunchAtLogin,
            environment.deleteUserData,
            environment.clearPreferences,
            environment.trashBundle,
        ]

        var leftovers: [UninstallFailure] = []
        for operation in bestEffort {
            if case .failure(let failure) = await operation() {
                leftovers.append(failure)
            }
        }

        state = leftovers.isEmpty ? .finished : .report(leftovers: leftovers)
    }

    public func acknowledgeReport() {
        guard case .report = state else { return }
        state = .finished
    }

    private func runPrecheck() async {
        for attempt in 1...Self.automaticGateAttempts {
            if let failure = await firstPrecheckFailure() {
                guard attempt == Self.automaticGateAttempts else { continue }
                state = .blocked(failure, offersDiagnostic: userRetryCount > 0)
                return
            }
            state = .awaitingConfirmation
            return
        }
    }

    private func firstPrecheckFailure() async -> UninstallFailure? {
        if case .failure(let failure) = await environment.releaseHolds() {
            return failure
        }
        if case .failure(let failure) = await environment.reconcileDaemon() {
            return failure
        }
        return nil
    }
}
