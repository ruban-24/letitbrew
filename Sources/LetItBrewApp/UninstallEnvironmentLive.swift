import AppKit
import LetItBrewAppCore
import LetItBrewCore
import Foundation

/// The model already owns every dependency this conformance needs — the
/// helper URL, UserDefaults, the daemon plumbing, and the hold-release path —
/// so a separate type would exist only to receive them all as closures. It
/// lives in its own file to keep the already-large model file from growing.
extension LetItBrewAppModel: UninstallEnvironment {
    private func failure<Success>(
        _ step: UninstallStep,
        _ message: String,
        _ diagnostic: String
    ) -> Result<Success, UninstallFailure> {
        .failure(UninstallFailure(step: step, message: message, diagnostic: diagnostic))
    }

    func releaseHolds() async -> Result<Void, UninstallFailure> {
        // Exactly the user-facing pause path: clears both power assertions, the
        // lid hold, and the daemon hold, and persists the choice — but,
        // unlike the plain Release action, this waits for all releases to
        // actually be confirmed rather than firing and forgetting, so a real
        // refusal (see PowerAssertions.swift IMPORTANT 3) blocks instead of
        // being silently discarded.
        guard await releaseHoldsAwaitingConfirmation() else {
            return failure(
                .releaseHolds,
                "Let It Brew could not confirm this Mac's sleep settings were fully restored. Nothing was removed.",
                "system/display power assertion release or daemon lid-hold release did not confirm"
            )
        }
        return .success(())
    }

    func reconcileDaemon() async -> Result<UninstallDaemonReconciliation, UninstallFailure> {
        // Service existence is never inferred from `keepWorkingWithLidClosed`
        // — turning that preference off releases the hold but never
        // unregisters the daemon (see `setKeepWorkingWithLidClosed`), so a
        // stale registered service can outlive the preference. Always ask
        // the daemon itself; `LiveDaemonUninstallPreparer.reconcile()` tells
        // "no service" apart from "a service exists and refused".
        switch await LiveDaemonUninstallPreparer.reconcile() {
        case .reconciled:
            return .success(.present)
        case .absent:
            return .success(.affirmativelyAbsent)
        case .failed(let detail):
            return failure(
                .reconcileDaemon,
                "Let It Brew could not safely confirm that its background service released the Mac's sleep setting. Restart your Mac, reopen Let It Brew, and try uninstalling again. Nothing was removed.",
                detail.message
            )
        }
    }

    func unregisterDaemon() async -> Result<Void, UninstallFailure> {
        // Called only after fresh reconciliation reports a present daemon;
        // never gate on the preference. A service can still disappear in the
        // small gap before this request, so preserve the existing idempotent
        // classification for that race.
        // `stopServiceForRefresh()` already maps an absent job to `.succeeded`
        // (see `LiveDaemonServiceController` / `DaemonRegistration.disposition`,
        // which classifies `kSMErrorJobNotFound` as `.alreadyUnregistered`).
        switch await LiveDaemonServiceController().stopServiceForRefresh() {
        case .succeeded:
            return .success(())
        case .approvalRequired(let message):
            return failure(.unregisterDaemon, message, "approvalRequired")
        case .ineligible(let message):
            // Correct to block (see the type's doc comment: an ineligible
            // copy's XPC identity derives from signing identity, not
            // location, so it cannot prove an eligible copy never registered
            // the same service) — only the message improves here, telling
            // the user how to actually finish instead of leaving them stuck.
            return failure(
                .unregisterDaemon,
                "This copy of Let It Brew can't manage its background service from here. Quit it, then uninstall from a properly signed Let It Brew installed directly at /Applications/Let It Brew.app — installing it there first if needed.",
                message
            )
        case .failed(let message):
            return failure(
                .unregisterDaemon,
                "Let It Brew could not stop its background service. Nothing was removed.",
                message
            )
        }
    }

    func removeClaudeHooks() async -> Result<Void, UninstallFailure> {
        await removeHooks(
            agentID: "claude",
            agentName: "Claude Code",
            step: .removeClaudeHooks
        )
    }

    func removeCodexHooks() async -> Result<Void, UninstallFailure> {
        await removeHooks(
            agentID: "codex",
            agentName: "Codex",
            step: .removeCodexHooks
        )
    }

    func removeOpenCodeHooks() async -> Result<Void, UninstallFailure> {
        await removeHooks(agentID: "opencode", agentName: "OpenCode", step: .removeOpenCodeHooks)
    }

    func removeCopilotHooks() async -> Result<Void, UninstallFailure> {
        await removeHooks(agentID: "copilot", agentName: "GitHub Copilot CLI", step: .removeCopilotHooks)
    }

    private func removeHooks(
        agentID: String,
        agentName: String,
        step: UninstallStep
    ) async -> Result<Void, UninstallFailure> {
        let helperURL = helperURL
        let results = await Task.detached(priority: .userInitiated) {
            AgentHelperBatchRunner.run(
                executableURL: helperURL,
                command: "uninstall",
                agentIDs: [agentID],
                timeout: 5
            )
        }.value
        guard let result = results.first else {
            return failure(
                step,
                "To remove Let It Brew's \(agentName) hooks, open Let It Brew—restoring it from the Trash first if needed—then choose Settings → Agents → \(agentName) → Disconnect before uninstalling again. Until then, the hooks are inert.",
                "no result"
            )
        }
        guard result.succeeded else {
            return failure(
                step,
                "To remove Let It Brew's \(agentName) hooks, open Let It Brew—restoring it from the Trash first if needed—then choose Settings → Agents → \(agentName) → Disconnect before uninstalling again. Until then, the hooks are inert.",
                result.timedOut ? "timed out" : "status \(result.status): \(result.output)"
            )
        }
        return .success(())
    }

    func disableLaunchAtLogin() async -> Result<Void, UninstallFailure> {
        let requester = loginItemRequester
        let result = await Task.detached(priority: .userInitiated) {
            requester.request(false)
        }.value
        switch result {
        case .succeeded:
            return .success(())
        case .failed(let launchAtLoginFailure):
            return failure(
                .disableLaunchAtLogin,
                "Open System Settings → General → Login Items & Extensions. Under Open at Login, select Let It Brew and click Remove (–). If Let It Brew appears under App Background Activity, turn it off.",
                launchAtLoginFailure.diagnostic
            )
        }
    }

    func deleteUserData() async -> Result<Void, UninstallFailure> {
        guard let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return failure(
                .deleteUserData,
                "Let It Brew could not locate its data folder automatically. In Finder, choose Go → Go to Folder…, enter ~/Library/Application Support/LetItBrew, then move that folder to the Trash if it exists.",
                "no user Application Support URL; no path was deleted"
            )
        }
        let directory = SessionStorage.applicationSupportDirectory(in: base)
        do {
            try FileManager.default.removeItem(at: directory)
            return .success(())
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain
            && error.code == NSFileNoSuchFileError {
            return .success(())
        } catch {
            return failure(
                .deleteUserData,
                "In Finder, choose Go → Go to Folder…, enter ~/Library/Application Support/LetItBrew, then move that folder to the Trash. It contains no personal data.",
                "\(directory.path): \(error.localizedDescription)"
            )
        }
    }

    func clearPreferences() async -> Result<Void, UninstallFailure> {
        guard let domain = Bundle.main.bundleIdentifier else {
            return failure(.clearPreferences, "Let It Brew could not identify its own preferences.", "nil bundleIdentifier")
        }
        // One domain removal, not a key list: a hand-maintained list would
        // drift from HoldSettingsPreferenceKey as settings are added.
        // ponytail: cfprefsd can re-flush a cached domain, so the app quits
        // immediately after this. The attended UAT reads the domain back,
        // which is the only place that re-flush is observable.
        defaults.removePersistentDomain(forName: domain)
        // DaemonRecoveryIntegration.swift already treats synchronize()
        // returning false as an explicit failure; discarding it here would
        // be inconsistent with that discipline for the exact same API.
        guard defaults.synchronize() else {
            return failure(
                .clearPreferences,
                "Open Terminal and run: defaults delete \(domain)",
                "UserDefaults.synchronize() returned false for domain \(domain)"
            )
        }
        return .success(())
    }

    func trashBundle() async -> Result<Void, UninstallFailure> {
        let bundleURL = Bundle.main.bundleURL
        do {
            let moved = try await NSWorkspace.shared.recycle([bundleURL])
            guard moved[bundleURL] != nil else {
                return failure(
                    .trashBundle,
                    "In Finder, open Applications and move \(bundleURL.lastPathComponent) to the Trash.",
                    "\(bundleURL.path): not present in the recycle result"
                )
            }
            return .success(())
        } catch {
            return failure(
                .trashBundle,
                "In Finder, open Applications and move \(bundleURL.lastPathComponent) to the Trash.",
                "\(bundleURL.path): \(error.localizedDescription)"
            )
        }
    }
}
