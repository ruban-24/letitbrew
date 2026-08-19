import Darwin
import Foundation
import LetItBrewCore

private func recentSessions(storage: SessionStorage, settings: Settings,
                            now: Date) -> [SessionRecord] {
    SessionStore.recent(records: storage.loadAll(), now: now, ttl: settings.staleTTL)
}

private func compactDuration(_ seconds: Int) -> String {
    if seconds >= 3_600 { return "\(seconds / 3_600)h" }
    if seconds >= 60 { return "\(seconds / 60)m" }
    return "\(seconds)s"
}

/// `letitbrew status`: one-shot board.
func runStatus(json: Bool) -> Int32 {
    let settings = Settings()
    let now = Date()
    let sessions = recentSessions(storage: SessionStorage(), settings: settings, now: now)
    let decision = decide(sessions: sessions, now: now, settings: settings,
                          power: IOKitPowerSource().current())

    if json {
        var payload: [String: Any] = [
            "holding": decision.holdSystem,
            "lid_closed": decision.holdLidClosed,
            "reason": decision.reason,
        ]
        payload["sessions"] = sessions.map { session -> [String: Any] in
            let age = max(0, Int(now.timeIntervalSince(session.updatedAt)))
            var entry: [String: Any] = [
                "id": session.id, "tool": session.tool, "repo": session.repoName,
                "state": session.state.rawValue,
                "seconds_in_state": age,
            ]
            if let detail = session.detail { entry["detail"] = detail }
            if let event = session.lastEvent { entry["last_event"] = event }
            if let activity = session.workingActivity(
                at: now,
                silentAfter: settings.workingSilenceThreshold
            ) {
                entry["activity"] = activity.rawValue
                if activity == .silent { entry["silent_seconds"] = age }
            }
            return entry
        }
        let data = try? JSONSerialization.data(withJSONObject: payload,
                                               options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data ?? Data("{}".utf8), as: UTF8.self))
    } else {
        print(decision.holdSystem ? "awake — \(decision.reason)" : "sleeping — \(decision.reason)")
        for session in sessions {
            let age = max(0, Int(now.timeIntervalSince(session.updatedAt)))
            let activity = session.workingActivity(
                at: now,
                silentAfter: settings.workingSilenceThreshold
            )
            let label = activity == .activeToolCall ? "active" : session.state.rawValue
            let annotation: String
            switch activity {
            case .activeToolCall:
                annotation = session.detail.map { " (\($0))" } ?? ""
            case .silent:
                let last = session.detail.map { "; last: \($0)" } ?? ""
                annotation = " (silent \(compactDuration(age))\(last))"
            case nil:
                annotation = session.detail.map { " (\($0))" } ?? ""
            }
            print("  \(label.padding(toLength: 8, withPad: " ", startingAt: 0))"
                  + " \(session.tool)  \(session.repoName)\(annotation)"
                  + "  \(compactDuration(age))")
        }
    }
    return decision.holdSystem ? 0 : 1
}

/// Message for `watch --lid-closed` refusing to start over a lease left by a
/// provably dead watchdog loop (the fail-closed lease repair path: see
/// `SleepWatchdogDebtCheck` — an owner that dies right after acquiring the
/// lease must never silently block every future engagement, but it must also
/// never be treated as clean without a human running `letitbrew repair`).
private func leaseRefusalMessage(for status: SleepWatchdogDebtStatus) -> String? {
    switch status {
    case .orphaned(let debt):
        return """
        Refusing to start lid-closed mode: a sleep watchdog (pid \(debt.watchdogPID)) engaged \
        disablesleep and died before restoring it to \(debt.priorValue ? "1" : "0"). \
        Run `letitbrew repair` to restore it and clear the lease, then try again.
        """
    case .unreadable:
        // Surfaced, never treated as clean: the debt record could not be
        // read, so the prior value it owes a restore to is unknown. Refuse
        // rather than guess.
        return """
        Refusing to start lid-closed mode: a sleep-watchdog lease exists but its record could \
        not be read, so it's unknown whether disablesleep still needs restoring. \
        Run `letitbrew repair` to clear it, then check `pmset -g | grep -i sleepdisabled` by hand.
        """
    case .held, .none:
        return nil
    }
}

/// `letitbrew watch`: tick once a second, applying the decision.
func runWatch(lidClosed: Bool) -> Int32 {
    let settings = Settings()
    let storage = SessionStorage()
    let assertion = IOKitPowerAssertion()
    let powerSource = IOKitPowerSource()
    let watchdog = OsascriptSleepWatchdog()
    let sleepSetting = PMSetSleepControl()

    // Prompt eagerly, at startup, rather than the first time agents get busy:
    // a lazy prompt would fire unattended in the middle of an overnight run
    // and block the very work it exists to protect.
    if lidClosed {
        let leaseStatus = SleepWatchdogDebtCheck.status(at: OsascriptSleepWatchdog.defaultLeaseURL)
        if let refusal = leaseRefusalMessage(for: leaseStatus) {
            FileHandle.standardError.write(Data("\(refusal)\n".utf8))
            return 1
        }

        switch watchdog.start(appPID: getpid()) {
        case .applied:
            print("Lid-closed mode armed.")
        case .cancelled:
            print("Lid-closed mode declined; system sleep only.")
            return 1
        case .failed(let message):
            FileHandle.standardError.write(Data("Watchdog failed: \(message)\n".utf8))
            return 1
        }
    }

    var weOwnLidHold = false
    var lastLoggedReason: String?
    var lastLoggedAt = Date.distantPast

    // No exit handler on purpose. Power assertions are owned by the kernel and
    // released when the process dies by any route, and the watchdog clears its
    // own flag when it sees this pid disappear. An atexit or signal handler
    // would add a path that cannot run on SIGKILL anyway, so the two mechanisms
    // that do survive a kill are the only ones worth relying on.
    print("Watching for agent sessions. Ctrl-C to stop.")

    while true {
        let now = Date()
        let sessions = recentSessions(storage: storage, settings: settings, now: now)
        let decision = decide(sessions: sessions, now: now, settings: settings,
                              power: powerSource.current())

        assertion.setSystemHold(decision.holdSystem, reason: decision.reason)

        if lidClosed {
            let wanted = decision.holdSystem && decision.holdLidClosed
            // Never coerce nil: `isSleepDisabled()` returning nil means the
            // flag was UNREADABLE this tick, not "enabled" or "disabled".
            // Guessing a boolean here could take or release a hold on false
            // information, so this tick's lid decision is skipped entirely
            // and retried on the next one.
            if let systemDisabled = sleepSetting.isSleepDisabled() {
                switch LidHold.next(desired: wanted, systemDisabled: systemDisabled, weOwn: weOwnLidHold) {
                case .take:
                    if watchdog.createFlag() { weOwnLidHold = true }
                case .release:
                    // Only forget ownership once the flag is CONFIRMED gone.
                    // If removal failed and the file is still on disk, the
                    // root loop stays engaged, but a `weOwn = false` here
                    // would make `LidHold.next` return `.none` forever —
                    // nothing would ever retry the removal. Leaving
                    // `weOwnLidHold` true lets the very next tick try again.
                    if watchdog.removeFlag() {
                        weOwnLidHold = false
                    }
                case .none:
                    break
                }
            }
        }

        if ReasonLog.shouldLog(reason: decision.reason, lastLogged: lastLoggedReason,
                               lastLoggedAt: lastLoggedAt, now: now) {
            let marker = decision.holdSystem ? "awake" : "idle "
            print("[\(ISO8601DateFormatter().string(from: now))] \(marker) — \(decision.reason)")
            lastLoggedReason = decision.reason
            lastLoggedAt = now
        }

        Thread.sleep(forTimeInterval: 1)
    }
}

/// `letitbrew repair`: clears a lease whose owning watchdog loop is provably
/// dead, so `watch --lid-closed` can engage again. Never touches a `.held`
/// lease — that one has a live owner. See the fail-closed lease design on
/// `SleepWatchdogDebtCheck`.
///
/// `status` and `live` are both read UNPRIVILEGED before `SleepWatchdogRepair
/// .run` ever decides anything — that decision, and the wiring around it
/// (never prompt on a refusal; try the free unprivileged delete before ever
/// escalating; escalate whenever a write is owed or that free delete
/// fails), is `SleepWatchdogRepair`'s job precisely so it's testable
/// without a real lease, `pmset`, or administrator prompt. The privileged
/// escalation itself, when it happens, re-derives everything again from
/// scratch — see `OsascriptSleepWatchdog.repairCommand`'s doc comment for
/// why that re-derivation, not this unprivileged read, is the actual
/// authority.
func runRepair() -> Int32 {
    let watchdog = OsascriptSleepWatchdog()
    let status = SleepWatchdogDebtCheck.status(at: OsascriptSleepWatchdog.defaultLeaseURL)
    let live = PMSetSleepControl().isSleepDisabled()

    let outcome = SleepWatchdogRepair.run(
        status: status, live: live,
        unprivilegedDelete: clearLeaseUnprivileged,
        escalate: { watchdog.repairOrphanedLease() })

    switch outcome {
    case .nothingToRepair:
        print("No lease to repair.")
        return 0
    case .refused(let message):
        FileHandle.standardError.write(Data("\(message)\n".utf8))
        return 1
    case .clearedWithoutPrivilege:
        print("Lease cleared.")
        return 0
    case .escalated(let result):
        return finishRepair(result)
    }
}

/// Removes the lease WITHOUT privilege, if that's even possible. This is an
/// ACTION, never a decision: a plain `rm -rf` can in fact remove even a
/// root-owned lease directory, because deleting a directory entry needs
/// write permission on its PARENT (`Let It Brew/`, created and owned by this
/// user), not ownership of the entry itself — so this must only ever run
/// once `SleepWatchdogRepair.run` has already decided nothing is owed.
/// Running it unconditionally, before that decision, is exactly what used
/// to strand `disablesleep=1` with no debt record.
private func clearLeaseUnprivileged() -> Bool {
    let lease = OsascriptSleepWatchdog.defaultLeaseURL
    try? FileManager.default.removeItem(at: lease)
    return !FileManager.default.fileExists(atPath: lease.path)
}

private func finishRepair(_ result: SleepSettingResult) -> Int32 {
    switch result {
    case .applied:
        print("Repaired: lease cleared.")
        return 0
    case .cancelled:
        print("Repair declined.")
        return 1
    case .failed(let message):
        FileHandle.standardError.write(Data("Repair failed: \(message)\n".utf8))
        return 1
    }
}
