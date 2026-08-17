import AppKit
import Combine
import Foundation
import os
import LetItBrewAppCore
import LetItBrewCore

enum LetItBrewPresentationState: String {
    case awake = "AWAKE"
    case idle = "IDLE"
    case paused = "PAUSED"
}

struct LetItBrewSnapshot: Sendable {
    let sessions: [SessionRecord]
    let power: PowerState
    let clamshell: ClamshellStateReading
    let displays: ActiveDisplayTopologyReading
    let now: Date
}

struct AgentHookHealth: Identifiable, Equatable, Sendable {
    typealias State = AgentConnectionState

    let id: String
    let name: String
    let state: State
    let details: [String]
    let disposition: AgentConnectionDisposition

    init(
        id: String,
        name: String,
        state: State,
        details: [String],
        disposition: AgentConnectionDisposition = .managed
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.details = details
        self.disposition = disposition
    }

    var requiresSetupAttention: Bool {
        AgentSetupAttentionPolicy.needsAttention(
            state: state,
            disposition: disposition
        )
    }

    var symbol: String {
        switch state {
        case .connecting: "clock"
        case .connected: "checkmark.circle.fill"
        case .actionNeeded: "exclamationmark.circle.fill"
        case .couldNotConnect: "exclamationmark.triangle.fill"
        }
    }
}

private struct HelperRunResult: Sendable {
    let status: Int32
    let output: String
    let timedOut: Bool
}

private enum DiskHookInspection: Sendable {
    case absent
    case healthy
    case needsConnection(details: [String])
    case invalid(details: [String])
}

private struct AgentConnectionRefresh: Sendable {
    let health: [AgentHookHealth]
    let changedAgents: [String]
}

private struct UserDefaultsLaunchAtLoginChoicePersistence: LaunchAtLoginChoicePersisting, @unchecked Sendable {
    let defaults: UserDefaults

    func loadChoice() -> Bool? {
        guard defaults.object(forKey: "launchAtLogin") != nil else { return nil }
        return defaults.bool(forKey: "launchAtLogin")
    }

    func saveChoice(_ enabled: Bool) {
        defaults.set(enabled, forKey: "launchAtLogin")
    }
}

private enum HoldSettingsPreferenceKey {
    static let pause = "letitbrewPaused"
    static let closedLidEnabled = "keepWorkingWithLidClosed"
    static let migrationCompleted = "holdSettingsMigrationV1Completed"
    static let legacySystemMode = "keepAwakeMode"
    static let legacyClosedLidMode = "lidClosedMode"
}

private struct UserDefaultsLetItBrewPausePersistence: LetItBrewPausePersisting, @unchecked Sendable {
    let defaults: UserDefaults

    func loadPause() -> Bool {
        defaults.bool(forKey: HoldSettingsPreferenceKey.pause)
    }

    func savePause(_ isPaused: Bool) {
        defaults.set(isPaused, forKey: HoldSettingsPreferenceKey.pause)
    }
}

private struct UserDefaultsLetItBrewSettingsMigrationPersistence:
    LetItBrewSettingsMigrationPersisting,
    @unchecked Sendable
{
    let defaults: UserDefaults

    func loadMigrationCompleted() -> Bool {
        defaults.bool(forKey: HoldSettingsPreferenceKey.migrationCompleted)
    }

    func loadExplicitPause() -> Bool? {
        optionalBool(forKey: HoldSettingsPreferenceKey.pause)
    }

    func loadExplicitClosedLidEnabled() -> Bool? {
        optionalBool(forKey: HoldSettingsPreferenceKey.closedLidEnabled)
    }

    func loadLegacySystemMode() -> String? {
        defaults.string(forKey: HoldSettingsPreferenceKey.legacySystemMode)
    }

    func loadLegacyClosedLidMode() -> String? {
        defaults.string(forKey: HoldSettingsPreferenceKey.legacyClosedLidMode)
    }

    func savePause(_ isPaused: Bool) {
        defaults.set(isPaused, forKey: HoldSettingsPreferenceKey.pause)
    }

    func saveClosedLidEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: HoldSettingsPreferenceKey.closedLidEnabled)
    }

    func discardLegacyHoldModes() {
        defaults.removeObject(forKey: HoldSettingsPreferenceKey.legacySystemMode)
        defaults.removeObject(forKey: HoldSettingsPreferenceKey.legacyClosedLidMode)
    }

    func markMigrationCompleted() {
        defaults.set(true, forKey: HoldSettingsPreferenceKey.migrationCompleted)
    }

    private func optionalBool(forKey key: String) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }
}

@MainActor
final class LetItBrewAppModel: ObservableObject {
    private static let logger = Logger(
        subsystem: "com.ruban24.letitbrew",
        category: "lid-close-display"
    )
    @Published private(set) var sessions: [MenuSessionPresentation] = []
    @Published private(set) var hasLoadedSessionSnapshot = false
    var sessionGroups: [MenuRepositoryPresentation] {
        MenuRepositoryPresentationPolicy.groups(from: sessions)
    }
    @Published private(set) var presentationState: LetItBrewPresentationState = .idle
    @Published private(set) var reason = "Your Mac can sleep"
    @Published private(set) var batteryDescription = "Reading power state…"
    @Published private(set) var daemonAvailable = false
    @Published private(set) var daemonMessage = "Checking closed-lid support…"
    @Published private(set) var daemonSetupInProgress = false
    @Published private(set) var daemonRecoveryState: DaemonRecoveryState = .checking
    @Published private(set) var ownsHold = false
    @Published private(set) var isPaused: Bool
    @Published private(set) var agentHooks = [
        AgentHookHealth(id: "claude", name: "Claude Code", state: .connecting, details: []),
        AgentHookHealth(id: "codex", name: "Codex", state: .connecting, details: []),
        AgentHookHealth(id: "cursor", name: "Cursor", state: .connecting, details: []),
        AgentHookHealth(id: "opencode", name: "OpenCode", state: .connecting, details: []),
        AgentHookHealth(id: "copilot", name: "GitHub Copilot CLI", state: .connecting, details: [])
    ]
    @Published private(set) var hookActionInProgress = false
    @Published private(set) var hookMessage: String?
    @Published private(set) var launchAtLogin = false
    @Published private(set) var launchAtLoginChoiceWasSaved = false
    @Published private(set) var showLaunchAtLoginOnboarding = false
    @Published private(set) var loginItemUpdateInProgress = false
    @Published private(set) var loginItemMessage: String?
    @Published private(set) var lidCloseDisplaySleepInProgress = false
    @Published private(set) var lidCloseDisplaySleepMessage: String?
    @Published private(set) var uninstallState: UninstallState = .idle
    @Published private(set) var uninstallInProgress = false
    @Published private(set) var uninstallReportIsPresented = false
    @Published private(set) var updateState: OneClickUpdateState = .idle
    @Published private(set) var updateInProgress = false
    @Published private(set) var updateCompletionReport: UpdateCompletionReport?
    @Published private(set) var keepWorkingWithLidClosed: Bool {
        didSet {
            defaults.set(
                keepWorkingWithLidClosed,
                forKey: HoldSettingsPreferenceKey.closedLidEnabled
            )
        }
    }
    @Published var batteryFloor: Double {
        didSet { defaults.set(batteryFloor, forKey: Keys.batteryFloor) }
    }

    private enum Keys {
        static let batteryFloor = "batteryFloor"
        static let launchAtLogin = "launchAtLogin"
        static let launchAtLoginOnboardingDismissed = "launchAtLoginOnboardingDismissed"
        static let disconnectedAgents = "disconnectedAgents"
        static let sessionTrackingSuppressions = "sessionTrackingSuppressionsV1"
    }

    let defaults: UserDefaults
    private let daemonRecoveryPersistence: UserDefaultsDaemonRecoveryPersistence
    private let storage: SessionStorage
    private let powerAssertion: PowerAsserting
    let loginItemRequester: LaunchAtLoginRequester
    private let loginItemRegistration: LoginItemRegistration
    private let clamshellMonitor: any ClamshellMonitoring
    private let activeDisplayMonitor: any ActiveDisplayMonitoring
    private let displaySleepExecutor: LidCloseDisplaySleepExecutor
    private let readsLiveState: Bool
    private let updateEnvironment: any OneClickUpdateEnvironment
    private let installedUpdateVersion: StableUpdateVersion?
    private let updateResultStore = LiveUpdateResultStore()
    private var pauseController: LetItBrewPauseController
    private var lidCloseDisplaySleepCoordinator = LidCloseDisplaySleepCoordinator()
    private var pollTask: Task<Void, Never>?
    private var updateResultTask: Task<Void, Never>?
    private var latestSnapshot: LetItBrewSnapshot?
    private var latestAppliedSnapshotAt: Date?
    private var daemonConnection: DaemonConnection?
    private var daemonRecoveryTask: Task<Void, Never>?
    private var daemonRecoveryGeneration: UInt64 = 0
    private var daemonWasHealthyThisRun = false
    private var daemonHandshakeInFlight = false
    private var daemonHoldRequestState = DaemonHoldRequestState()
    private var requestedLidHold = false
    private var appliedLidHold: Bool?
    private var requestedSystemHold = false
    private var lastDaemonAttempt = Date.distantPast
    private var nextDaemonHealthCheck = Date.distantPast
    private var sessionTrackingSuppressions: [SessionTrackingSuppression]
    private var wasPausedBeforeUninstall: Bool?

    init(
        defaults: UserDefaults = .standard,
        storage: SessionStorage = SessionStorage(),
        powerAssertion: PowerAsserting = IOKitPowerAssertion(),
        loginItemRegistration: LoginItemRegistration = LoginItemRegistration(),
        clamshellMonitor: any ClamshellMonitoring = IOKitClamshellMonitor(),
        activeDisplayMonitor: any ActiveDisplayMonitoring = CoreGraphicsActiveDisplayMonitor(),
        displaySleepCommand: any DisplaySleepCommanding = PMSetDisplaySleepCommand(),
        updateEnvironment: (any OneClickUpdateEnvironment)? = nil,
        installedUpdateVersion: StableUpdateVersion? = nil,
        startsPolling: Bool = true
    ) {
        self.defaults = defaults
        daemonRecoveryPersistence = UserDefaultsDaemonRecoveryPersistence(
            defaults: defaults
        )
        self.storage = storage
        self.powerAssertion = powerAssertion
        self.loginItemRegistration = loginItemRegistration
        self.clamshellMonitor = clamshellMonitor
        self.activeDisplayMonitor = activeDisplayMonitor
        self.updateEnvironment = updateEnvironment ?? LiveOneClickUpdateEnvironment()
        self.installedUpdateVersion = installedUpdateVersion ?? Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ).flatMap { StableUpdateVersion($0 as? String ?? "") }
        sessionTrackingSuppressions = Self.loadSessionTrackingSuppressions(
            from: defaults
        )
        displaySleepExecutor = LidCloseDisplaySleepExecutor(command: displaySleepCommand)
        loginItemRequester = LaunchAtLoginRequester(
            registration: loginItemRegistration,
            persistence: UserDefaultsLaunchAtLoginChoicePersistence(
                defaults: defaults
            )
        )
        let migratedSettings = LetItBrewSettingsMigrator.migrateIfNeeded(
            using: UserDefaultsLetItBrewSettingsMigrationPersistence(defaults: defaults)
        )
        let loadedPauseController = LetItBrewPauseController(
            persistence: UserDefaultsLetItBrewPausePersistence(defaults: defaults)
        )
        pauseController = loadedPauseController
        isPaused = loadedPauseController.isPaused
        readsLiveState = startsPolling
        keepWorkingWithLidClosed = migratedSettings.isClosedLidEnabled
        batteryFloor = Self.persistedDouble(
            defaults, key: Keys.batteryFloor, allowed: 5...50, fallback: 20
        )
        launchAtLoginChoiceWasSaved = defaults.object(forKey: Keys.launchAtLogin) != nil
        launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        showLaunchAtLoginOnboarding = !launchAtLoginChoiceWasSaved
            && !defaults.bool(forKey: Keys.launchAtLoginOnboardingDismissed)

        if startsPolling {
            startPolling()
            startPendingUpdateResultPolling()
            runDaemonRecovery(trigger: .automaticLaunch)
            refreshAgentHooks()
        }
    }

    deinit {
        pollTask?.cancel()
        updateResultTask?.cancel()
        daemonRecoveryTask?.cancel()
        powerAssertion.setSystemHold(false, reason: "Let It Brew quit")
        daemonConnection?.invalidate()
    }

    var menuBarAccessibilityLabel: String {
        "Let It Brew, \(presentationState.rawValue.lowercased()), \(reason)"
    }

    var isHolding: Bool {
        ownsHold
    }

    var lidControlHelp: String? {
        daemonAvailable ? nil : daemonMessage
    }

    var daemonRecoveryPresentation: DaemonRecoveryPresentation {
        DaemonRecoveryPresentation(state: daemonRecoveryState)
    }

    var daemonNeedsSetupAttention: Bool {
        keepWorkingWithLidClosed && daemonRecoveryPresentation.requiresAttention
    }

    func setKeepWorkingWithLidClosed(_ enabled: Bool) {
        keepWorkingWithLidClosed = enabled
        if !enabled {
            requestedLidHold = false
            synchronizeDaemonHold()
            if !daemonAvailable {
                applyDaemonRecoveryState(.deferredUntilEnabled)
            }
        } else if !daemonAvailable {
            runDaemonRecovery(trigger: .automaticLaunch)
        }
        refreshNow()
    }

    func refreshNow() {
        guard readsLiveState else { return }
        Task { [weak self] in
            await self?.pollOnce()
        }
    }

    @discardableResult
    func allowMacToSleep() -> Bool {
        pauseController.pause()
        isPaused = true
        requestedSystemHold = false
        let systemReleased = powerAssertion.setSystemHold(false, reason: "Released by user")
        requestedLidHold = false
        synchronizeDaemonHold()
        updateHoldOwnership()
        refreshNow()
        return systemReleased
    }

    /// The uninstall `releaseHolds` gate's version of the Release action.
    /// `allowMacToSleep()` only fires the daemon-side lid-hold release via
    /// `synchronizeDaemonHold()` and moves on — that call's XPC completion
    /// runs later, asynchronously, on its own. This waits for that attempt
    /// (or one a poll tick already had in flight) to actually settle and
    /// reports whether both the local assertion and the daemon hold are
    /// confirmed released, so a real refusal blocks uninstall instead of
    /// vanishing into a completion handler nobody awaited. See
    /// PowerAssertions.swift's IMPORTANT 3 for the same discipline applied to
    /// the local assertion.
    func releaseHoldsAwaitingConfirmation() async -> Bool {
        let daemonWasAvailable = daemonAvailable
        let systemReleased = allowMacToSleep()
        guard daemonWasAvailable else { return systemReleased }

        // Bounded: a wedged daemon completion must not hang uninstall
        // forever. Not settling within two seconds is treated as failure.
        for _ in 0..<20 where daemonHoldRequestState.isInFlight {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let daemonReleased = !daemonHoldRequestState.isInFlight
            && daemonAvailable
            && appliedLidHold != true
        return systemReleased && daemonReleased
    }

    private lazy var uninstallCoordinator = UninstallCoordinator(environment: self)

    private lazy var updateCoordinator: OneClickUpdateCoordinator? = {
        guard let installedUpdateVersion else { return nil }
        return OneClickUpdateCoordinator(
            installedVersion: installedUpdateVersion,
            environment: updateEnvironment
        )
    }()

    var updateBlocksOtherActions: Bool {
        if updateInProgress || updateCompletionReport != nil { return true }
        return switch updateState {
        case .available, .readyToQuit:
            true
        case .idle, .checking, .upToDate, .installing, .failed:
            false
        }
    }

    func checkForUpdates() {
        runUpdate(beginning: .checking) { await $0.check() }
    }

    func confirmUpdate() {
        guard case .available(let release) = updateState else { return }
        runUpdate(beginning: .installing(release)) { await $0.confirmInstall() }
    }

    func cancelUpdate() {
        guard !updateInProgress else { return }
        if let updateCoordinator {
            updateCoordinator.cancelInstall()
            updateState = updateCoordinator.state
        } else {
            updateState = .idle
        }
    }

    func retryUpdate() {
        guard case .failed(_, let retry) = updateState else { return }
        let beginning: OneClickUpdateState = switch retry {
        case .check:
            .checking
        case .install(let release):
            .installing(release)
        }
        runUpdate(beginning: beginning) { await $0.retry() }
    }

    func dismissUpdateStatus() {
        guard !updateInProgress else { return }
        if let updateCoordinator {
            updateCoordinator.dismissStatus()
            updateState = updateCoordinator.state
        } else {
            updateState = .idle
        }
    }

    func updateDiagnostic(for failure: OneClickUpdateFailure) -> String {
        failure.diagnostic
    }

    func revealUpdateLog(_ report: UpdateCompletionReport) {
        guard let logFile = report.logFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([logFile])
    }

    func dismissUpdateCompletionReport() {
        guard let report = updateCompletionReport else { return }
        updateResultStore.dismiss(report)
        updateCompletionReport = nil
    }

    private func runUpdate(
        beginning state: OneClickUpdateState,
        _ operation: @escaping (OneClickUpdateCoordinator) async -> Void
    ) {
        guard !updateInProgress,
              !uninstallInProgress,
              uninstallState != .awaitingConfirmation,
              !hookActionInProgress,
              !loginItemUpdateInProgress,
              updateCompletionReport == nil
        else { return }
        guard let updateCoordinator else {
            updateState = .failed(
                OneClickUpdateFailure(
                    message: "Let It Brew couldn't identify its installed version. Nothing was changed.",
                    diagnostic: "CFBundleShortVersionString is missing or is not canonical major.minor.patch"
                ),
                retry: .check
            )
            return
        }

        // Set synchronously. SwiftUI writes a confirmation dialog's binding
        // to false after every button, including Install; this distinguishes
        // the confirmed operation from a real cancellation.
        updateInProgress = true
        updateState = state
        Task { [weak self] in
            guard let self else { return }
            await operation(updateCoordinator)
            self.updateState = updateCoordinator.state
            self.updateInProgress = false
            if case .readyToQuit = self.updateState {
                // Give SwiftUI one main-actor turn to dismiss the dialog before
                // asking AppKit to terminate, matching the proven uninstall
                // modal-dismissal discipline.
                DispatchQueue.main.async {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    private func startPendingUpdateResultPolling() {
        updateResultTask?.cancel()
        let store = updateResultStore
        updateResultTask = Task { [weak self] in
            var pendingWorkspace: URL?
            for _ in 0..<240 {
                guard !Task.isCancelled else { return }
                let scan = await Task.detached(priority: .utility) {
                    store.scan()
                }.value
                guard let self else { return }
                switch scan {
                case .none:
                    return
                case .waiting(let workspace):
                    pendingWorkspace = workspace
                case .report(let report):
                    self.updateCompletionReport = report
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard let self, let pendingWorkspace else { return }
            self.updateCompletionReport = store.timedOutReport(for: pendingWorkspace)
        }
    }

    func beginUninstall() {
        guard UninstallPauseRestorationPolicy.canBegin(state: uninstallState)
        else { return }
        let wasPaused = isPaused
        if runUninstall({ await $0.beginPrecheck() }) {
            wasPausedBeforeUninstall = wasPaused
        }
    }

    func retryUninstall() {
        _ = runUninstall { await $0.retryPrecheck() }
    }

    func confirmUninstall() {
        _ = runUninstall { await $0.confirm() }
    }

    func cancelUninstall() {
        uninstallCoordinator.cancel()
        uninstallState = uninstallCoordinator.state
        let shouldResume = UninstallPauseRestorationPolicy
            .shouldResumeAfterCancellation(
                wasPausedBeforeUninstall: wasPausedBeforeUninstall
            )
        wasPausedBeforeUninstall = nil
        if shouldResume {
            resumeLetItBrew()
        }
    }

    func resumeAfterBlockedUninstall() {
        guard case .blocked = uninstallState, !uninstallInProgress else { return }
        uninstallCoordinator.cancel()
        uninstallState = uninstallCoordinator.state
        wasPausedBeforeUninstall = nil
        resumeLetItBrew()
    }

    func acknowledgeUninstallReport() {
        guard case .report = uninstallState else { return }
        uninstallCoordinator.acknowledgeReport()
        uninstallState = uninstallCoordinator.state
        uninstallReportIsPresented = false
        wasPausedBeforeUninstall = nil
        terminateAfterUninstallUISettles()
    }

    func uninstallReportDidAppear() {
        guard case .report = uninstallState else { return }
        uninstallReportIsPresented = true
    }

    func uninstallReportDidDisappear() {
        uninstallReportIsPresented = false
    }

    /// One copyable block for a bug report. Deliberately carries no project
    /// paths or agent configuration.
    func uninstallDiagnostic(for failures: [UninstallFailure]) -> String {
        failures
            .map { "\($0.step.rawValue): \($0.diagnostic)" }
            .joined(separator: "\n")
    }

    private func runUninstall(
        _ operation: @escaping (UninstallCoordinator) async -> Void
    ) -> Bool {
        // Uninstall removes the same hook entries and login item that a
        // hook-refresh or Launch-at-Login change mutates in its own
        // untracked task; without this, an agent repair could re-install
        // hook entries while uninstall is removing them. Reusing the
        // model's existing in-progress flags avoids new state for the same
        // mutual exclusion `refreshAgentHooks`/`disconnectAgents`/
        // `setLaunchAtLogin` enforce from their side below.
        guard !uninstallInProgress,
              !hookActionInProgress,
              !loginItemUpdateInProgress,
              !updateBlocksOtherActions
        else { return false }
        uninstallInProgress = true
        Task { [weak self] in
            guard let self else { return }
            await operation(self.uninstallCoordinator)
            self.uninstallInProgress = false
            self.uninstallState = self.uninstallCoordinator.state
            if self.uninstallState == .finished {
                self.wasPausedBeforeUninstall = nil
                self.terminateAfterUninstallUISettles()
            }
        }
        return true
    }

    private func terminateAfterUninstallUISettles() {
        // The confirmation dialog or leftovers sheet is still dismissing when
        // the coordinator reaches `.finished`. Asking AppKit to terminate in
        // that same main-actor turn can be ignored while the modal UI is
        // active, leaving the process running from the bundle now in Trash.
        // Queue termination after SwiftUI has observed the finished state and
        // dismissed its presentation.
        DispatchQueue.main.async {
            NSApp.terminate(nil)
        }
    }

    func resumeLetItBrew() {
        pauseController.resume()
        isPaused = false
        refreshNow()
    }

    /// Compatibility for the existing popover while its controls are being
    /// replaced. The user action now creates the same persisted pause as
    /// `allowMacToSleep()` rather than mutating the old hold-mode settings.
    func releaseLetItBrewHolds() {
        allowMacToSleep()
    }

    func retryDaemonConnection() {
        runDaemonRecovery(trigger: .userRequestedRetry)
    }

    func setUpDaemon() {
        runDaemonRecovery(trigger: .userRequestedSetup)
    }

    func revealSessionFolder() {
        NSWorkspace.shared.open(SessionStorage.sessionsDirectory)
    }

    /// Stops one session from contributing to either the menu or awake
    /// decision. A newer genuine work edge automatically clears the durable
    /// suppression for this same session.
    func stopTrackingSession(id: String, toolID: String) {
        guard let session = latestSnapshot?.sessions.first(where: {
            $0.id == id && $0.tool.caseInsensitiveCompare(toolID) == .orderedSame
        }) else {
            return
        }
        sessionTrackingSuppressions.removeAll {
            $0.sessionID == id && $0.toolID == session.tool.lowercased()
        }
        sessionTrackingSuppressions.append(SessionTrackingSuppression(session: session))
        sessionTrackingSuppressions.sort {
            ($0.toolID, $0.sessionID) < ($1.toolID, $1.sessionID)
        }
        saveSessionTrackingSuppressions()
        reapplyLatestSnapshot()
    }

    func refreshAgentHooks() {
        refreshAgentHooks(agentIDs: Set(AgentID.allCases.map(\.rawValue)))
    }

    func refreshCodexTrustIfNeeded() {
        guard let codex = agentHooks.first(where: { $0.id == "codex" }),
              CodexTrustAutoRefreshPolicy.shouldRefresh(
                  state: codex.state,
                  disposition: codex.disposition
              )
        else { return }
        refreshAgentHooks(agentIDs: ["codex"])
    }

    func applicationDidBecomeActive() {
        refreshCodexTrustIfNeeded()
        guard !uninstallInProgress,
              !updateBlocksOtherActions,
              case .approvalRequired = daemonRecoveryState
        else { return }
        runDaemonRecovery(trigger: .userRequestedRetry)
    }

    private func refreshAgentHooks(
        agentIDs: Set<String>,
        messageAfterRefresh: String? = nil
    ) {
        // Must not start once uninstall has: uninstall removes these same
        // hook entries, and a repair here would re-install them mid-teardown.
        guard !hookActionInProgress, !uninstallInProgress, !updateBlocksOtherActions else { return }
        let requested = agentIDs.intersection(Set(AgentID.allCases.map(\.rawValue)))
        guard !requested.isEmpty else { return }
        let helperPath = helperURL.path
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        let codexExecutable = CodexExecutableLocator.locate()
        let appVersion = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "development"
        let disconnected = disconnectedAgentIDs
        let mutationDecision = AutomaticHookMutationPolicy.evaluate(
            appBundleURL: Bundle.main.bundleURL
        )
        hookActionInProgress = true
        hookMessage = nil
        agentHooks = agentHooks.map { health in
            guard requested.contains(health.id) else { return health }
            return disconnected.contains(health.id)
                ? AgentHookHealth(
                    id: health.id, name: health.name, state: .actionNeeded,
                    details: ["Disconnected. Choose Connect to use this agent with Let It Brew."],
                    disposition: .intentionallyDisconnected
                )
                : AgentHookHealth(id: health.id, name: health.name, state: .connecting, details: [])
        }
        Task { [weak self] in
            let refresh = await Task.detached(priority: .utility) {
                Self.connectAgentHooks(
                    cliPath: helperPath,
                    home: home,
                    environment: environment,
                    codexExecutable: codexExecutable,
                    appVersion: appVersion,
                    disconnected: disconnected,
                    agentIDs: requested,
                    mutationDecision: mutationDecision
                )
            }.value
            guard let self else { return }
            let refreshed = Dictionary(uniqueKeysWithValues: refresh.health.map { ($0.id, $0) })
            self.agentHooks = self.agentHooks.map { refreshed[$0.id] ?? $0 }
            self.hookActionInProgress = false
            if !refresh.changedAgents.isEmpty {
                self.hookMessage = "Connected \(refresh.changedAgents.joined(separator: " and ")). Restart agent sessions that were already open."
            } else {
                self.hookMessage = messageAfterRefresh
            }
        }
    }

    func installOrRepairHooks() {
        refreshAgentHooks()
    }

    func uninstallHooks() {
        disconnectAgents(Set(AgentID.allCases.map(\.rawValue)))
    }

    /// Explicit API for the Agents overflow menu. Automatic setup respects
    /// this durable choice until `connectAgent` is called.
    func disconnectAgent(_ id: String) {
        guard AgentID(rawValue: id) != nil else { return }
        disconnectAgents([id])
    }

    func connectAgent(_ id: String) {
        guard AgentID(rawValue: id) != nil else { return }
        saveDisconnectedAgentIDs(AgentDisconnectPersistence.clearingIntent(
            for: id,
            from: disconnectedAgentIDs
        ))
        reapplyLatestSnapshot()
        refreshAgentHooks(agentIDs: [id])
    }

    /// Explicit per-agent model API for a UI "Check Again" action. This does
    /// not silently reverse a user's durable Disconnect choice.
    func retryAgentConnection(_ id: String) {
        guard AgentID(rawValue: id) != nil else { return }
        refreshAgentHooks(agentIDs: [id])
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        // Must not start once uninstall has: uninstall itself turns off
        // Launch at Login, and this must not race that.
        guard !loginItemUpdateInProgress, !uninstallInProgress, !updateBlocksOtherActions else { return }
        loginItemUpdateInProgress = true
        loginItemMessage = nil
        let requester = loginItemRequester
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                requester.request(enabled)
            }.value
            guard let self else { return }
            self.loginItemUpdateInProgress = false
            switch result {
            case .failed(let failure):
                self.loginItemMessage = failure.message
            case .succeeded(let enabled):
                self.launchAtLogin = enabled
                self.launchAtLoginChoiceWasSaved = true
                self.showLaunchAtLoginOnboarding = false
                self.defaults.set(true, forKey: Keys.launchAtLoginOnboardingDismissed)
            }
        }
    }

    func dismissLaunchAtLoginOnboarding() {
        showLaunchAtLoginOnboarding = false
        defaults.set(true, forKey: Keys.launchAtLoginOnboardingDismissed)
    }

    func openLoginItemSettings() {
        loginItemRegistration.openSystemSettings()
    }

    private func startPolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    var helperURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/letitbrew")
    }

    private var disconnectedAgentIDs: Set<String> {
        Set(defaults.stringArray(forKey: Keys.disconnectedAgents) ?? [])
    }

    private func saveDisconnectedAgentIDs(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: Keys.disconnectedAgents)
    }

    private func disconnectAgents(_ ids: Set<String>) {
        // Same mutual exclusion as refreshAgentHooks(): must not start once
        // uninstall has, since uninstall removes these same hook entries.
        guard !hookActionInProgress, !uninstallInProgress, !updateBlocksOtherActions else { return }
        let requested = ids.intersection(Set(AgentID.allCases.map(\.rawValue)))
        guard !requested.isEmpty else { return }
        let recordedIntent = AgentDisconnectPersistence.recordingIntent(
            for: requested,
            into: disconnectedAgentIDs
        )
        saveDisconnectedAgentIDs(recordedIntent)
        reapplyLatestSnapshot()
        let mutationDecision = AutomaticHookMutationPolicy.evaluate(
            appBundleURL: Bundle.main.bundleURL
        )
        if case .actionNeeded(let details) = mutationDecision {
            agentHooks = agentHooks.map { health in
                guard requested.contains(health.id) else { return health }
                return AgentHookHealth(
                    id: health.id,
                    name: health.name,
                    state: .actionNeeded,
                    details: details + [
                        "Let It Brew will not repair or reinstall this connection unless you choose Connect."
                    ],
                    disposition: .disconnectFailed
                )
            }
            hookMessage = details.joined(separator: " ")
            return
        }
        let helperURL = helperURL
        hookActionInProgress = true
        hookMessage = nil
        Task { [weak self] in
            let results = await Task.detached(priority: .userInitiated) {
                AgentHelperBatchRunner.run(
                    executableURL: helperURL,
                    command: "uninstall",
                    agentIDs: requested.sorted(),
                    timeout: 5
                )
            }.value
            guard let self else { return }
            self.hookActionInProgress = false
            let followUps = AgentDisconnectCompletionPolicy.followUps(for: results)
            let followUpByAgent = Dictionary(uniqueKeysWithValues: followUps.map { followUp in
                switch followUp {
                case .markDisconnected(let agentID):
                    (agentID, followUp)
                case .showFailure(let result):
                    (result.agentID, followUp)
                }
            })
            self.agentHooks = self.agentHooks.map { health in
                guard let followUp = followUpByAgent[health.id] else { return health }
                switch followUp {
                case .markDisconnected:
                    return AgentHookHealth(
                        id: health.id,
                        name: health.name,
                        state: .actionNeeded,
                        details: ["Disconnected. Choose Connect to use this agent with Let It Brew."],
                        disposition: .intentionallyDisconnected
                    )
                case .showFailure(let result):
                    return AgentHookHealth(
                        id: health.id,
                        name: health.name,
                        state: .couldNotConnect,
                        details: [
                            Self.disconnectFailureMessage([result]),
                            "Let It Brew will not repair or reinstall this connection unless you choose Connect.",
                        ],
                        disposition: .disconnectFailed
                    )
                }
            }

            let successful = results.filter(\.succeeded).map(\.agentID)
            let failed = results.filter { !$0.succeeded }
            let message: String
            if failed.isEmpty {
                message = "Disconnected \(successful.sorted().joined(separator: " and "))."
            } else if successful.isEmpty {
                message = Self.disconnectFailureMessage(failed)
            } else {
                message = "Disconnected \(successful.sorted().joined(separator: " and ")). \(Self.disconnectFailureMessage(failed))"
            }
            self.hookMessage = message
        }
    }

    private nonisolated static func runHelper(
        at path: String,
        arguments: [String],
        input: Data? = nil
    ) -> HelperRunResult {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return HelperRunResult(
                status: -1,
                output: "The embedded Let It Brew helper is missing.",
                timedOut: false
            )
        }
        let result = BoundedProcessRunner.run(
            executableURL: URL(fileURLWithPath: path),
            arguments: arguments,
            input: input,
            timeout: 5
        )
        let output = result.timedOut
            ? "Let It Brew’s agent helper timed out. Choose Check Again."
            : result.launchError ?? String(decoding: result.output, as: UTF8.self)
        return HelperRunResult(
            status: result.status,
            output: output,
            timedOut: result.timedOut
        )
    }

    /// Read-only app-side half of the exact handoff. The snapshot and the
    /// expected ownership state are serialized to the helper, which verifies
    /// them again before it changes either registry or vendor configuration.
    private nonisolated static func prepareExact(
        agent: AgentID, cliPath: String, home: URL, environment: [String: String]
    ) -> HelperRunResult {
        do {
            let registryURL = home.appendingPathComponent("Library/Application Support/LetItBrew/agent-hook-targets.json")
            let registry: AgentInstallRegistry?
            if let data = try? Data(contentsOf: registryURL) {
                registry = try? JSONDecoder().decode(AgentInstallRegistry.self, from: data)
            } else { registry = nil }
            let configured: URL
            switch agent {
            case .claude: configured = ClaudeHooks.settingsURL(home: home)
            case .codex: configured = CodexHooks.hooksURL(home: home, environment: environment)
            case .cursor: configured = CursorHooks.settingsURL(home: home)
            case .opencode: configured = OpenCodePlugin.pluginURL(home: home, environment: environment)
            case .copilot: configured = CopilotHooks.hooksURL(home: home, environment: environment)
            }
            // A known target is authoritative even when vendor homes moved.
            // JSON symlinks are followed only for the first handoff, matching
            // the CLI's one-time final-target recording rule.
            let target: URL
            if let recorded = registry?.targets[agent] { target = URL(fileURLWithPath: recorded) }
            else if agent != .opencode { target = configured.resolvingSymlinksInPath().standardizedFileURL }
            else { target = configured }
            let capture = try ExactFileCapture.capture(at: target)
            let report: HookInstallReport
            switch agent {
            case .claude:
                _ = try ClaudeHooks.install(into: capture.data, cliPath: cliPath); report = ClaudeHooks.report(for: capture.data, cliPath: cliPath)
            case .codex:
                _ = try CodexHooks.install(into: capture.data, cliPath: cliPath); report = CodexHooks.report(for: capture.data, cliPath: cliPath)
            case .cursor:
                _ = try CursorHooks.install(into: capture.data, cliPath: cliPath); report = CursorHooks.report(for: capture.data, cliPath: cliPath)
            case .opencode:
                _ = try OpenCodePlugin.install(into: capture.data, cliPath: cliPath); report = OpenCodePlugin.report(for: capture.data, cliPath: cliPath)
            case .copilot:
                _ = try CopilotHooks.install(into: capture.data, cliPath: cliPath); report = CopilotHooks.report(for: capture.data, cliPath: cliPath)
            }
            let state: ExactTargetExpectedState = !capture.snapshot.exists ? .absent : report.isHealthy ? .healthyOwned : report.isAbsent ? .absent : .repairableOwned
            let preparation = try ExactTargetPreparation(agent: agent, snapshot: capture.snapshot, expectedState: state)
            return runHelper(at: cliPath, arguments: ["prepare-exact", agent.rawValue], input: try JSONEncoder().encode(preparation))
        } catch {
            return HelperRunResult(status: 1, output: "Exact preparation refused: \(error)", timedOut: false)
        }
    }

    private nonisolated static func inspectClaudeHooks(
        cliPath: String,
        home: URL
    ) -> DiskHookInspection {
        do {
            let data = try ClaudeHooks.read(at: ClaudeHooks.settingsURL(home: home))
            _ = try ClaudeHooks.remove(from: data)
            let report = ClaudeHooks.report(for: data, cliPath: cliPath)
            if report.isAbsent { return .absent }
            return report.isHealthy ? .healthy : .needsConnection(details: hookReportDetails(report))
        } catch {
            let path = ClaudeHooks.settingsURL(home: home).path
            return .invalid(
                details: AgentConfigRecoveryGuidance.details(
                    agentName: "Claude", path: path
                )
            )
        }
    }

    private nonisolated static func inspectCodexHooks(
        cliPath: String,
        home: URL,
        environment: [String: String]
    ) -> DiskHookInspection {
        do {
            let url = CodexHooks.hooksURL(home: home, environment: environment)
            let data = try CodexHooks.read(at: url)
            _ = try CodexHooks.remove(from: data)
            let report = CodexHooks.report(for: data, cliPath: cliPath)
            if report.isAbsent { return .absent }
            return report.isHealthy ? .healthy : .needsConnection(details: hookReportDetails(report))
        } catch {
            let path = CodexHooks.hooksURL(home: home, environment: environment).path
            return .invalid(
                details: AgentConfigRecoveryGuidance.details(
                    agentName: "Codex", path: path
                )
            )
        }
    }

    private nonisolated static func disconnectedHealth(
        id: String,
        name: String,
        inspection: DiskHookInspection,
        mutationGuidance: [String]?
    ) -> AgentHookHealth {
        switch inspection {
        case .absent:
            return AgentHookHealth(
                id: id,
                name: name,
                state: .actionNeeded,
                details: ["Disconnected. Choose Connect to use this agent with Let It Brew."],
                disposition: .intentionallyDisconnected
            )
        case .healthy, .needsConnection:
            return AgentHookHealth(
                id: id,
                name: name,
                state: .couldNotConnect,
                details: [
                    "Let It Brew’s hooks are still present, so disconnect did not finish.",
                    "Let It Brew will not repair or reinstall them. Choose Disconnect again to retry, or Connect to keep using this agent.",
                ] + (mutationGuidance ?? []),
                disposition: .disconnectFailed
            )
        case .invalid(let details):
            return AgentHookHealth(
                id: id,
                name: name,
                state: .actionNeeded,
                details: details + [
                    "Let It Brew will not repair or reinstall this connection. Fix the file, then choose Disconnect again, or choose Connect to keep using this agent."
                ] + (mutationGuidance ?? []),
                disposition: .disconnectFailed
            )
        }
    }

    private nonisolated static func connectAgentHooks(
        cliPath: String,
        home: URL,
        environment: [String: String],
        codexExecutable: URL?,
        appVersion: String,
        disconnected: Set<String>,
        agentIDs: Set<String>,
        mutationDecision: AutomaticHookMutationDecision
    ) -> AgentConnectionRefresh {
        var changedAgents: [String] = []
        var health: [AgentHookHealth] = []
        let mutationGuidance: [String]?
        switch mutationDecision {
        case .eligible:
            mutationGuidance = nil
        case .actionNeeded(let details):
            mutationGuidance = details
        }

        if agentIDs.contains("claude"), !AgentAutomaticConnectionPolicy.mayMutate(
            agentID: "claude", recordedDisconnectIntents: disconnected
        ) {
            health.append(disconnectedHealth(
                id: "claude",
                name: "Claude Code",
                inspection: inspectClaudeHooks(cliPath: cliPath, home: home),
                mutationGuidance: mutationGuidance
            ))
        } else if agentIDs.contains("claude") {
            var inspection = inspectClaudeHooks(cliPath: cliPath, home: home)
            var mutation: HelperRunResult?
            if let mutationGuidance {
                let details: [String]
                if case .invalid(let invalidDetails) = inspection {
                    details = invalidDetails + mutationGuidance
                } else {
                    details = mutationGuidance
                }
                health.append(AgentHookHealth(
                    id: "claude", name: "Claude Code", state: .actionNeeded,
                    details: details
                ))
            } else {
                if case .absent = inspection {
                    mutation = prepareExact(agent: .claude, cliPath: cliPath, home: home, environment: environment)
                    inspection = inspectClaudeHooks(cliPath: cliPath, home: home)
                } else if case .needsConnection = inspection {
                    mutation = prepareExact(agent: .claude, cliPath: cliPath, home: home, environment: environment)
                    inspection = inspectClaudeHooks(cliPath: cliPath, home: home)
                }

                switch inspection {
                case .absent:
                    health.append(AgentHookHealth(
                        id: "claude", name: "Claude Code", state: .couldNotConnect,
                        details: connectionFailureDetails(
                            mutation,
                            fallback: ["Let It Brew could not add its Claude Code hooks."]
                        )
                    ))
                case .healthy:
                    let changed = mutation?.status == 0
                    if changed { changedAgents.append("Claude Code") }
                    var details = ["Local CLI and Desktop Code sessions"]
                    if changed { details.append("Restart sessions that were already open.") }
                    health.append(AgentHookHealth(
                        id: "claude", name: "Claude Code", state: .connected,
                        details: details
                    ))
                case .needsConnection(let details):
                    health.append(AgentHookHealth(
                        id: "claude", name: "Claude Code", state: .couldNotConnect,
                        details: connectionFailureDetails(mutation, fallback: details)
                    ))
                case .invalid(let details):
                    health.append(AgentHookHealth(
                        id: "claude", name: "Claude Code", state: .actionNeeded,
                        details: details
                    ))
                }
            }
        }

        if agentIDs.contains("codex"), !AgentAutomaticConnectionPolicy.mayMutate(
            agentID: "codex", recordedDisconnectIntents: disconnected
        ) {
            health.append(disconnectedHealth(
                id: "codex",
                name: "Codex",
                inspection: inspectCodexHooks(
                    cliPath: cliPath, home: home, environment: environment
                ),
                mutationGuidance: mutationGuidance
            ))
        } else if agentIDs.contains("codex") {
            var inspection = inspectCodexHooks(
                cliPath: cliPath, home: home, environment: environment
            )
            var mutation: HelperRunResult?
            if let mutationGuidance {
                let details: [String]
                if case .invalid(let invalidDetails) = inspection {
                    details = invalidDetails + mutationGuidance
                } else {
                    details = mutationGuidance
                }
                health.append(AgentHookHealth(
                    id: "codex", name: "Codex", state: .actionNeeded,
                    details: details
                ))
            } else {
                if case .absent = inspection {
                    mutation = prepareExact(agent: .codex, cliPath: cliPath, home: home, environment: environment)
                    inspection = inspectCodexHooks(
                        cliPath: cliPath, home: home, environment: environment
                    )
                } else if case .needsConnection = inspection {
                    mutation = prepareExact(agent: .codex, cliPath: cliPath, home: home, environment: environment)
                    inspection = inspectCodexHooks(
                        cliPath: cliPath, home: home, environment: environment
                    )
                }

                switch inspection {
                case .absent:
                    health.append(AgentHookHealth(
                        id: "codex", name: "Codex", state: .couldNotConnect,
                        details: connectionFailureDetails(
                            mutation,
                            fallback: ["Let It Brew could not add its Codex hooks."]
                        )
                    ))
                case .healthy:
                    let changed = mutation?.status == 0
                    if changed { changedAgents.append("Codex") }
                    let hooksURL = CodexHooks.hooksURL(home: home, environment: environment)
                    let trust = LiveCodexHookTrustInspection.inspect(
                        executableURL: codexExecutable,
                        hooksURL: hooksURL,
                        cwd: home,
                        appVersion: appVersion
                    )
                    let policy = AgentConnectionPolicy.state(
                        configuration: .healthy,
                        codexTrust: trust
                    )
                    switch policy {
                    case .connected:
                        var details = ["Local CLI and Codex app sessions"]
                        if changed { details.append("Restart sessions that were already open.") }
                        health.append(AgentHookHealth(
                            id: "codex", name: "Codex", state: .connected,
                            details: details
                        ))
                    case .actionNeeded:
                        health.append(AgentHookHealth(
                            id: "codex", name: "Codex", state: .actionNeeded,
                            details: [
                                "In Codex, type /hooks and approve Let It Brew.",
                                "Then restart Codex sessions that were already open.",
                            ]
                        ))
                    case .couldNotConnect:
                        health.append(AgentHookHealth(
                            id: "codex", name: "Codex", state: .couldNotConnect,
                            details: [
                                "Let It Brew added its hooks but couldn’t verify Codex approval.",
                                "Open Codex, then try again.",
                            ]
                        ))
                    case .connecting:
                        health.append(AgentHookHealth(
                            id: "codex", name: "Codex", state: .connecting,
                            details: []
                        ))
                    }
                case .needsConnection(let details):
                    health.append(AgentHookHealth(
                        id: "codex", name: "Codex", state: .couldNotConnect,
                        details: connectionFailureDetails(mutation, fallback: details)
                    ))
                case .invalid(let details):
                    health.append(AgentHookHealth(
                        id: "codex", name: "Codex", state: .actionNeeded,
                        details: details
                    ))
                }
            }
        }

        // The remaining integrations share the exact helper protocol. They
        // deliberately do not probe whether a vendor executable is installed:
        // hook configuration is local and independent of that discovery.
        for agent in [AgentID.cursor, .opencode, .copilot] where agentIDs.contains(agent.rawValue) {
            if !AgentAutomaticConnectionPolicy.mayMutate(agentID: agent.rawValue, recordedDisconnectIntents: disconnected) {
                health.append(AgentHookHealth(id: agent.rawValue, name: agent.displayName, state: .actionNeeded, details: ["Disconnected. Choose Connect to use this agent with Let It Brew."], disposition: .intentionallyDisconnected))
                continue
            }
            if mutationGuidance != nil {
                health.append(AgentHookHealth(id: agent.rawValue, name: agent.displayName, state: .actionNeeded, details: mutationGuidance!))
                continue
            }
            let mutation = prepareExact(agent: agent, cliPath: cliPath, home: home, environment: environment)
            if mutation.status == 0 {
                changedAgents.append(agent.displayName)
                health.append(AgentHookHealth(id: agent.rawValue, name: agent.displayName, state: .connected, details: ["Restart sessions that were already open."]))
            } else {
                health.append(AgentHookHealth(id: agent.rawValue, name: agent.displayName, state: .couldNotConnect, details: connectionFailureDetails(mutation, fallback: ["Let It Brew could not prepare its \(agent.displayName) connection."])))
            }
        }

        return AgentConnectionRefresh(
            health: health,
            changedAgents: changedAgents
        )
    }

    private nonisolated static func disconnectFailureMessage(
        _ results: [AgentHelperOperationResult]
    ) -> String {
        let names = results.map {
            $0.agentID == "claude" ? "Claude Code" : "Codex"
        }.joined(separator: " and ")
        let firstDetail = results.lazy.map {
            $0.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first { !$0.isEmpty }
        return firstDetail ?? "Couldn’t disconnect \(names). Choose Disconnect again."
    }

    private nonisolated static func connectionFailureDetails(
        _ mutation: HelperRunResult?,
        fallback: [String]
    ) -> [String] {
        guard let mutation else { return fallback }
        let message = mutation.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? fallback : [message]
    }

    private nonisolated static func persistedDouble(
        _ defaults: UserDefaults,
        key: String,
        allowed: ClosedRange<Double>,
        fallback: Double
    ) -> Double {
        guard let value = defaults.object(forKey: key) as? Double,
              value.isFinite,
              allowed.contains(value)
        else { return fallback }
        return value
    }

    private nonisolated static func loadSessionTrackingSuppressions(
        from defaults: UserDefaults
    ) -> [SessionTrackingSuppression] {
        guard let data = defaults.data(forKey: Keys.sessionTrackingSuppressions),
              let decoded = try? JSONDecoder().decode(
                  [SessionTrackingSuppression].self,
                  from: data
              )
        else { return [] }
        return decoded
    }

    private func saveSessionTrackingSuppressions() {
        if sessionTrackingSuppressions.isEmpty {
            defaults.removeObject(forKey: Keys.sessionTrackingSuppressions)
            return
        }
        guard let data = try? JSONEncoder().encode(sessionTrackingSuppressions) else {
            return
        }
        defaults.set(data, forKey: Keys.sessionTrackingSuppressions)
    }

    private nonisolated static func hookReportDetails(_ report: HookInstallReport) -> [String] {
        var details: [String] = []
        func append(_ label: String, _ events: Set<String>) {
            guard !events.isEmpty else { return }
            details.append("\(label): \(events.sorted().joined(separator: ", "))")
        }
        append("Missing", report.missing)
        append("Stale path", report.stale)
        append("Duplicated", report.duplicated)
        append("Retired", report.orphaned)
        return details
    }

    private func pollOnce() async {
        let storage = storage
        let clamshellMonitor = clamshellMonitor
        let activeDisplayMonitor = activeDisplayMonitor
        let snapshot = await Task.detached(priority: .utility) {
            let now = Date()
            let records = SessionStore.recent(
                records: storage.loadAll(),
                now: now,
                ttl: 12 * 3_600
            )
            return LetItBrewSnapshot(
                sessions: records,
                power: IOKitPowerSource().current(),
                clamshell: clamshellMonitor.currentClamshellState(),
                displays: activeDisplayMonitor.currentDisplayTopology(),
                now: now
            )
        }.value
        guard MenuSnapshotOrderPolicy.shouldApply(
            candidateObservedAt: snapshot.now,
            latestAppliedAt: latestAppliedSnapshotAt
        ) else { return }
        latestAppliedSnapshotAt = snapshot.now
        apply(snapshot)
    }

    private func runDaemonRecovery(trigger: DaemonRecoveryTrigger) {
        guard daemonRecoveryTask == nil else { return }

        let context: DaemonRecoveryContext
        do {
            context = try LiveDaemonRecoveryContext.make(
                closedLidEnabled: keepWorkingWithLidClosed
            )
        } catch {
            applyDaemonRecoveryState(.ineligible(message: error.localizedDescription))
            return
        }

        daemonRecoveryGeneration &+= 1
        let generation = daemonRecoveryGeneration
        daemonConnection?.invalidate()
        daemonConnection = nil
        daemonAvailable = false
        daemonHandshakeInFlight = false
        daemonHoldRequestState.replaceConnection()
        appliedLidHold = nil
        updateHoldOwnership()

        let persistence = daemonRecoveryPersistence
        let coordinator = DaemonRecoveryCoordinator(
            handshakeChecker: LiveDaemonHandshakeChecker(),
            serviceController: LiveDaemonServiceController(),
            persistence: persistence,
            stateObserver: { [weak self] state in
                Task { @MainActor in
                    guard let self,
                          self.daemonRecoveryGeneration == generation
                    else { return }
                    self.applyDaemonRecoveryState(state)
                }
            }
        )

        daemonRecoveryTask = Task { [weak self] in
            let finalState = await coordinator.run(
                context: context,
                trigger: trigger
            )
            guard let self,
                  self.daemonRecoveryGeneration == generation
            else { return }
            self.daemonRecoveryTask = nil
            self.applyDaemonRecoveryState(finalState)
            if finalState == .ready {
                self.connectToDaemon()
            }
        }
    }

    private func applyDaemonRecoveryState(_ state: DaemonRecoveryState) {
        daemonRecoveryState = state
        let presentation = DaemonRecoveryPresentation(state: state)
        daemonMessage = if let detail = presentation.detail {
            "\(presentation.headline) \(detail)"
        } else {
            presentation.headline
        }
        daemonSetupInProgress = presentation.showsProgress
    }

    private func apply(_ snapshot: LetItBrewSnapshot) {
        latestSnapshot = snapshot
        let connectedSessions = AgentSessionVisibilityPolicy.visibleSessions(
            from: snapshot.sessions,
            disconnectedAgentIDs: disconnectedAgentIDs
        )
        let tracking = SessionTrackingPolicy.applying(
            sessionTrackingSuppressions,
            to: connectedSessions
        )
        if tracking.suppressions != sessionTrackingSuppressions {
            sessionTrackingSuppressions = tracking.suppressions
            saveSessionTrackingSuppressions()
        }
        applyVisibleSnapshot(LetItBrewSnapshot(
            sessions: tracking.sessions,
            power: snapshot.power,
            clamshell: snapshot.clamshell,
            displays: snapshot.displays,
            now: snapshot.now
        ))
        hasLoadedSessionSnapshot = true
    }

    private func reapplyLatestSnapshot() {
        guard let latestSnapshot else {
            refreshNow()
            return
        }
        apply(latestSnapshot)
    }

    private func applyVisibleSnapshot(_ snapshot: LetItBrewSnapshot) {
        var settings = LetItBrewCore.Settings()
        settings.batteryFloor = Int(batteryFloor.rounded())

        sessions = MenuSessionPresentationPolicy.rows(
            from: snapshot.sessions.map { Self.menuInput($0, now: snapshot.now) },
            now: snapshot.now
        )

        let decision = decide(
            sessions: snapshot.sessions,
            now: snapshot.now,
            settings: settings,
            power: snapshot.power
        )
        let safetyPaused = !snapshot.power.trusted
            || (snapshot.power.onBattery && snapshot.power.batteryPercent <= settings.batteryFloor)
            || snapshot.power.thermal == .serious
            || snapshot.power.thermal == .critical

        let holdIntent = pauseController.resolve(
            systemHold: !safetyPaused && decision.holdSystem,
            lidClosedHold: !safetyPaused
                && keepWorkingWithLidClosed
                && decision.holdLidClosed
        )
        let allowedSystemHold = holdIntent.system
        requestedSystemHold = holdIntent.system
        requestedLidHold = holdIntent.lidClosed

        evaluateLidCloseDisplaySleep(snapshot: snapshot)

        powerAssertion.setSystemHold(
            allowedSystemHold,
            reason: "Let It Brew: \(decision.reason)"
        )
        synchronizeDaemonHold()
        updateHoldOwnership()

        if daemonAvailable,
           snapshot.now >= nextDaemonHealthCheck,
           !daemonHoldRequestState.isInFlight {
            synchronizeDaemonHold(force: true)
        }

        if daemonWasHealthyThisRun,
           !daemonAvailable,
           Date().timeIntervalSince(lastDaemonAttempt) >= 5,
           !daemonHandshakeInFlight,
           daemonRecoveryTask == nil {
            connectToDaemon()
        }

        let isKeepingAwake = allowedSystemHold
            || (requestedLidHold && appliedLidHold == true)
        let releaseConstraint: MenuHeaderCopy.ReleaseConstraint? = if !sessions.isEmpty {
            if !snapshot.power.trusted {
                .powerUnavailable
            } else if snapshot.power.onBattery,
                      snapshot.power.batteryPercent <= settings.batteryFloor {
                .battery(percent: snapshot.power.batteryPercent)
            } else if snapshot.power.thermal == .serious
                        || snapshot.power.thermal == .critical {
                .thermal
            } else {
                nil
            }
        } else {
            nil
        }
        if isPaused {
            presentationState = .paused
        } else if isKeepingAwake {
            presentationState = .awake
        } else {
            presentationState = .idle
        }
        reason = MenuHeaderCopy.resolve(
            isPaused: isPaused,
            isKeepingAwake: isKeepingAwake,
            releaseConstraint: releaseConstraint
        )

        if snapshot.power.onBattery {
            batteryDescription = "Battery \(snapshot.power.batteryPercent)%"
        } else if snapshot.power.trusted {
            batteryDescription = "Power adapter"
        } else {
            batteryDescription = "Power state unavailable"
        }

    }

    private func evaluateLidCloseDisplaySleep(snapshot: LetItBrewSnapshot) {
        let action = lidCloseDisplaySleepCoordinator.evaluate(
            clamshell: snapshot.clamshell,
            displays: snapshot.displays,
            letitbrewOwnsOrNeedsLidHold: requestedLidHold && daemonAvailable
        )
        guard action == .sleepDisplays, !lidCloseDisplaySleepInProgress else { return }

        Self.logger.notice("Observed an eligible closed-lid display transition; requesting display sleep.")
        lidCloseDisplaySleepInProgress = true
        let executor = displaySleepExecutor
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                executor.perform(action)
            }.value
            guard let self else { return }
            self.lidCloseDisplaySleepInProgress = false
            switch result {
            case .succeeded:
                Self.logger.notice("Display sleep request succeeded.")
                self.lidCloseDisplaySleepMessage = nil
            case .failed(let message):
                Self.logger.error("Display sleep request failed: \(message, privacy: .public)")
                self.lidCloseDisplaySleepMessage = "Could not sleep displays for closed-lid work: \(message)"
            case nil:
                break
            }
        }
    }

    private func connectToDaemon() {
        guard !daemonHandshakeInFlight else { return }
        lastDaemonAttempt = Date()
        daemonHandshakeInFlight = true
        do {
            let connection = try DaemonConnection()
            daemonConnection = connection
            connection.connect { [weak self, weak connection] result in
                Task { @MainActor in
                    guard let self, self.daemonConnection === connection else { return }
                    self.daemonHandshakeInFlight = false
                    switch result {
                    case .success:
                        self.daemonWasHealthyThisRun = true
                        self.daemonAvailable = true
                        self.applyDaemonRecoveryState(.ready)
                        self.appliedLidHold = nil
                        self.nextDaemonHealthCheck = .distantPast
                        self.synchronizeDaemonHold()
                    case .failure(let error):
                        self.markDaemonUnavailable(error.localizedDescription)
                    }
                }
            }
        } catch {
            daemonHandshakeInFlight = false
            markDaemonUnavailable(error.localizedDescription)
        }
    }

    private func synchronizeDaemonHold(force: Bool = false) {
        guard daemonAvailable,
              !daemonHoldRequestState.isInFlight,
              force || appliedLidHold != requestedLidHold,
              let connection = daemonConnection
        else { return }

        let desired = requestedLidHold
        guard let request = daemonHoldRequestState.beginRequest() else { return }
        connection.setLidClosedHold(desired) { [weak self, weak connection] result in
            Task { @MainActor in
                guard let self,
                      self.daemonHoldRequestState.complete(request),
                      self.daemonConnection === connection
                else { return }
                switch result {
                case .success:
                    self.appliedLidHold = desired
                    self.nextDaemonHealthCheck = Date().addingTimeInterval(desired ? 5 : 15)
                    self.updateHoldOwnership()
                    if self.requestedLidHold != desired {
                        self.synchronizeDaemonHold()
                    }
                case .failure(let error):
                    self.markDaemonUnavailable(error.localizedDescription)
                }
            }
        }
    }

    private func markDaemonUnavailable(_ message: String) {
        daemonAvailable = false
        applyDaemonRecoveryState(.retryableFailure(.handshakeFailed(
            message: message
        )))
        daemonHandshakeInFlight = false
        daemonHoldRequestState.replaceConnection()
        appliedLidHold = nil
        daemonConnection?.invalidate()
        daemonConnection = nil
        updateHoldOwnership()
    }

    private func updateHoldOwnership() {
        ownsHold = requestedSystemHold || (requestedLidHold && appliedLidHold == true)
    }

    private static func menuInput(_ record: SessionRecord, now: Date) -> SessionMenuInput {
        let state: MenuSessionState = switch record.state {
        case .working: .working
        case .idle: .idle
        }
        return SessionMenuInput(
            id: record.id,
            tool: record.tool,
            project: record.repoName,
            repositoryPath: record.repositoryID,
            state: state,
            activeWorkingTime: record.activeWorkingTime(at: now),
            updatedAt: record.updatedAt
        )
    }
}

extension LetItBrewAppModel {
    static func preview(
        sessions: [SessionRecord],
        power: PowerState = PowerState(onBattery: false, batteryPercent: 100, thermal: .nominal),
        now: Date = Date()
    ) -> LetItBrewAppModel {
        let defaults = UserDefaults(suiteName: "LetItBrewPreview-\(UUID().uuidString)")!
        let model = LetItBrewAppModel(
            defaults: defaults,
            powerAssertion: PreviewPowerAssertion(),
            startsPolling: false
        )
        model.daemonAvailable = true
        model.applyDaemonRecoveryState(.ready)
        model.apply(LetItBrewSnapshot(
            sessions: sessions,
            power: power,
            clamshell: .open,
            displays: .noExternalDisplay,
            now: now
        ))
        return model
    }
}

private final class PreviewPowerAssertion: PowerAsserting, @unchecked Sendable {
    func setSystemHold(_ on: Bool, reason: String) -> Bool { true }
}
