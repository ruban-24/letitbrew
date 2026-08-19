import Foundation

/// A record the root loop leaves inside its exclusive lease directory the
/// instant it takes on the responsibility of restoring `pmset disablesleep`,
/// written BEFORE it ever writes the setting. A debt held only in a shell
/// variable dies with the loop — on disk, a later run (or the
/// `doctor`) can find it and act.
public struct SleepWatchdogDebt: Equatable, Sendable {
    /// The app run that requested this engagement. Informational only —
    /// liveness is NOT based on this pid, because the app can be alive while
    /// its watchdog loop is dead, which is exactly the condition this API
    /// exists to catch.
    public let appPID: Int32
    /// The root watchdog loop's own pid (`$$` inside the backgrounded
    /// subshell). Liveness is checked against THIS.
    public let watchdogPID: Int32
    /// The watchdog loop's process start time, exactly as `ps -o lstart=`
    /// reported it when the loop began. Bound alongside the pid so a reused
    /// pid can't fool the detector either — the same identity binding the
    /// loop uses on the app's own pid.
    public let watchdogStartedAt: String
    /// The value `disablesleep` held before this run engaged. Restoring to
    /// THIS — not a hardcoded 0 — is what lets a value the user set by hand
    /// survive a session this app never asked to change it.
    public let priorValue: Bool
    public let setAt: Date

    public init(
        appPID: Int32, watchdogPID: Int32, watchdogStartedAt: String, priorValue: Bool, setAt: Date
    ) {
        self.appPID = appPID
        self.watchdogPID = watchdogPID
        self.watchdogStartedAt = watchdogStartedAt
        self.priorValue = priorValue
        self.setAt = setAt
    }

    /// Parses the `key=value` marker the shell loop writes with `printf`.
    /// Nil for a missing file, an unreadable one, a non-positive pid, or any
    /// field that doesn't parse — fail closed rather than guess at a
    /// malformed debt's shape.
    public static func load(from url: URL) -> SleepWatchdogDebt? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var fields: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            fields[String(parts[0])] = String(parts[1])
        }

        guard let appPIDText = fields["app_pid"], let appPID = Int32(appPIDText), appPID > 0,
            let watchdogPIDText = fields["watchdog_pid"], let watchdogPID = Int32(watchdogPIDText),
            watchdogPID > 0,
            let watchdogStartedAt = fields["watchdog_start"], !watchdogStartedAt.isEmpty,
            let priorText = fields["prior"],
            let setAtText = fields["setAt"], let epoch = TimeInterval(setAtText)
        else { return nil }

        let priorValue: Bool
        switch priorText {
        case "0": priorValue = false
        case "1": priorValue = true
        default: return nil
        }

        return SleepWatchdogDebt(
            appPID: appPID, watchdogPID: watchdogPID, watchdogStartedAt: watchdogStartedAt,
            priorValue: priorValue, setAt: Date(timeIntervalSince1970: epoch))
    }
}

/// Whether an on-disk debt is still being watched by a live watchdog loop.
public enum SleepWatchdogDebtStatus: Equatable, Sendable {
    /// No lease on disk.
    case none
    /// A lease exists but its debt record could not be read or parsed. This
    /// is dangerous — it may represent a real, unrestored `disablesleep` —
    /// so it gets its own status rather than being silently treated as
    /// `.none`.
    case unreadable
    /// A debt exists and its owning watchdog loop is still alive.
    case held(SleepWatchdogDebt)
    /// A debt exists and no live watchdog owns it: `disablesleep` may still
    /// be stuck at a value nothing will ever restore. Actionable.
    case orphaned(SleepWatchdogDebt)
}

/// Reads a lease and classifies it against watchdog-loop liveness. Kept
/// separate from `OsascriptSleepWatchdog` because only the root loop itself
/// ever writes to or removes the lease; this side only ever reads it, and
/// never overwrites or deletes anything — repair belongs to the watchdog.
public enum SleepWatchdogDebtCheck {
    public static func status(
        at leaseURL: URL,
        isWatchdogAlive: (Int32, String) -> Bool = defaultIsWatchdogAlive
    ) -> SleepWatchdogDebtStatus {
        guard FileManager.default.fileExists(atPath: leaseURL.path) else { return .none }
        guard let debt = SleepWatchdogDebt.load(from: leaseURL.appendingPathComponent("debt"))
        else { return .unreadable }
        return isWatchdogAlive(debt.watchdogPID, debt.watchdogStartedAt)
            ? .held(debt) : .orphaned(debt)
    }

    /// Liveness bound to pid + start time, exactly like the loop's own
    /// identity check on the app's pid — a bare `kill(pid, 0)` alone could
    /// be fooled by pid reuse just as easily here as in the loop itself.
    public static func defaultIsWatchdogAlive(pid: Int32, expectedStart: String) -> Bool {
        guard pid > 0, KillZeroLiveness().isAlive(pid: pid) else { return false }
        return currentProcessStartTime(pid: pid) == expectedStart
    }

    /// Shells out to `ps -o lstart=`, matching exactly how the shell loop
    /// itself produces and records the value being compared against — a
    /// sysctl-derived timestamp would use a different representation and
    /// could never be compared to it directly.
    static func currentProcessStartTime(pid: Int32) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "lstart=", "-p", String(pid)]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            // Trailing NEWLINES only, matching exactly what the shell loop's
            // own `$(ps -o lstart= ...)` command substitution keeps: shell
            // strips trailing newlines but nothing else, and `ps` pads
            // `lstart` with trailing spaces on this platform — trimming
            // those too would make this never match what the loop recorded.
            var text = String(decoding: data, as: UTF8.self)
            while text.hasSuffix("\n") { text.removeLast() }
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }
}

/// What `letitbrew repair` did, decided and carried out against injected
/// side-effecting actions rather than the real filesystem/`pmset`/osascript
/// directly — so the WIRING (never escalate on a refusal; try the free
/// unprivileged delete before ever prompting; escalate whenever a `pmset`
/// write is owed or that free delete fails) is testable without touching
/// any of them for real.
public enum SleepWatchdogRepairOutcome: Equatable, Sendable {
    case nothingToRepair
    case refused(String)
    case clearedWithoutPrivilege
    case escalated(SleepSettingResult)
}

public enum SleepWatchdogRepair {
    /// Decides what to do from state that's cheap and safe to read WITHOUT
    /// administrator privileges — `status` is already an unprivileged, real
    /// pid+start-time liveness check (see `SleepWatchdogDebtCheck`), and
    /// `live` is an ordinary unprivileged `pmset -g` read — then carries it
    /// out via `unprivilegedDelete` and `escalate`.
    ///
    /// This unprivileged read is an OPTIMISATION to skip the administrator
    /// prompt when it provably isn't needed, NEVER a second source of
    /// truth: `escalate` (in production, `OsascriptSleepWatchdog.
    /// repairOrphanedLease`) re-derives this exact same decision from
    /// scratch, inside the privileged shell, the instant it actually runs —
    /// because that prompt can sit open for an arbitrary time and the
    /// world, including the lease's own content, can change while it
    /// waits. If the two ever disagree, the privileged re-derivation wins;
    /// this function only ever decides whether to prompt at all, never what
    /// happens once escalated.
    ///
    /// `unprivilegedDelete` is tried ONLY once this decides nothing is
    /// owed — never before, and never for a refusal. A plain `rm -rf` can
    /// in fact remove even a root-owned lease directory (removing a
    /// directory entry needs write permission on its PARENT, not ownership
    /// of the entry — and the parent, `Let It Brew/`, is created and owned by
    /// this user), which is exactly why it must never run unconditionally:
    /// running it before this decision is made is what stranded
    /// `disablesleep=1` with no debt record in the first place.
    public static func run(
        status: SleepWatchdogDebtStatus,
        live: Bool?,
        unprivilegedDelete: () -> Bool,
        escalate: () -> SleepSettingResult
    ) -> SleepWatchdogRepairOutcome {
        switch status {
        case .none:
            return .nothingToRepair

        case .held(let debt):
            return .refused(
                "Lease is held by a live watchdog (pid \(debt.watchdogPID)); nothing to repair.")

        case .orphaned(let debt):
            guard let live else {
                return .refused(
                    "Could not read the current disablesleep value, so it's unknown whether a "
                        + "restore to \(debt.priorValue ? "1" : "0") is still owed. Not touching "
                        + "anything; check `pmset -g` by hand.")
            }
            guard live == debt.priorValue else {
                // A restore is owed; that needs a `pmset` write, which
                // needs root. No unprivileged shortcut applies.
                return .escalated(escalate())
            }
            return unprivilegedDelete() ? .clearedWithoutPrivilege : .escalated(escalate())

        case .unreadable:
            guard let live else {
                return .refused(
                    "Could not read the current disablesleep value, so it's unknown whether this "
                        + "unreadable lease record is safe to discard. Not touching anything; "
                        + "check `pmset -g` by hand.")
            }
            guard !live else {
                return .refused(
                    "This lease record could not be read, so it's unknown whether disablesleep=1 "
                        + "is something you set or something we set and lost the record of. "
                        + "Refusing to change it automatically -- if you are sure it is safe, "
                        + "run: sudo pmset -a disablesleep 0")
            }
            return unprivilegedDelete() ? .clearedWithoutPrivilege : .escalated(escalate())
        }
    }
}

/// Real backend. The flag is a file in Application Support; the loop runs as
/// root via `osascript`'s "with administrator privileges", backgrounded so the
/// prompt returns as soon as the loop is alive.
public final class OsascriptSleepWatchdog: @unchecked Sendable {
    private let flagURL: URL
    private let leaseURL: URL

    public init(
        flagURL: URL = OsascriptSleepWatchdog.defaultFlagURL,
        leaseURL: URL = OsascriptSleepWatchdog.defaultLeaseURL
    ) {
        self.flagURL = flagURL
        self.leaseURL = leaseURL
    }

    private static var applicationSupportBase: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    /// A per-launch nonce, generated once and cached for this process's
    /// lifetime (not per access — every call must see the same value, or
    /// two reads within the same run would disagree on the app's own path).
    private static let launchNonce = UUID().uuidString.prefix(8)

    /// Per-launch: a leftover flag from a crashed run must never be mistaken
    /// for THIS run's request, and an exiting old watchdog must never delete
    /// a newer run's flag. Baking a fresh nonce into the path for every
    /// launch makes both impossible — the two runs simply never share a
    /// path, so neither can observe or touch the other's flag.
    public static var defaultFlagURL: URL {
        applicationSupportBase.appendingPathComponent(
            "Let It Brew/sleep-watchdog-\(launchNonce).flag", isDirectory: false)
    }

    /// Fixed, NOT per-launch: unlike the flag, the lease must be
    /// discoverable by a later, different run — that's the whole point of
    /// detecting an orphaned debt after a crash. It is also a DIRECTORY: an
    /// atomic `mkdir` on this exact path is the exclusivity primitive that
    /// keeps two engagements from ever clobbering each other's debt record.
    public static var defaultLeaseURL: URL {
        applicationSupportBase.appendingPathComponent(
            "Let It Brew/sleep-watchdog.lease", isDirectory: true)
    }

    public func isFlagPresent() -> Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    public func createFlag() -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: flagURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: flagURL)
            return true
        } catch {
            return false
        }
    }

    /// CRITICAL 2: the actual outcome of the removal attempt is what
    /// determines success — never `fileExists` afterward, which conflates
    /// genuine absence with a stat/access FAILURE (an inaccessible path also
    /// reads back as "does not exist"). `removeItem` throwing "no such
    /// file" means the flag was already gone, which is success same as a
    /// clean removal; any OTHER error (permission denied, an immutable
    /// flag, an inaccessible parent) is a genuine failure, and `runWatch`
    /// must keep ownership so the next tick retries rather than forgetting
    /// it forever.
    public func removeFlag() -> Bool {
        do {
            try FileManager.default.removeItem(at: flagURL)
            return true
        } catch {
            let error = error as NSError
            return error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError
        }
    }

    /// True only for AppleScript's canonical user-cancelled-authorization
    /// error, `(-128)`. A free-text "cancel" match would also swallow a
    /// genuine failure whose message happens to mention cancellation.
    static func isUserCancelledAuthorization(stderr: String) -> Bool {
        stderr.contains("(-128)")
    }

    /// The root loop, backgrounded so `do shell script` returns immediately.
    ///
    /// It lives exactly as long as the app's pid AND that pid's process
    /// start time (captured once at launch, re-checked every cycle) — a bare
    /// `kill -0` alone would keep watching an unrelated process once the pid
    /// is reused.
    ///
    /// It follows the control flag, **edge-triggered**: on the rising edge
    /// it reads the CURRENT `disablesleep` value (never guessing — an
    /// unreadable read refuses to engage) and records it as the restore
    /// debt, not a hardcoded "off". Engaging first takes an ATOMIC EXCLUSIVE
    /// LEASE via `mkdir` on a fixed path: `mkdir` either creates the
    /// directory or fails if it already exists, with no race window, so two
    /// engagements (this run retried, another run, a stale run) can never
    /// overwrite each other's debt record — the loop simply refuses to
    /// engage while any lease exists. The debt record lives INSIDE that
    /// lease directory, written before `pmset` is ever touched, and the
    /// lease is released only after a restore is CONFIRMED by reading the
    /// value back — an unreadable confirmation is never treated as success,
    /// so a failed restore keeps the debt (and the lease) for a later run to
    /// settle rather than silently discarding the only record of how to
    /// undo it.
    ///
    /// The engage write's own confirmation read applies that SAME "clear
    /// only on a confirmed match to prior" rule, not a hardcoded "0": the
    /// lease is released without committing only when the read-back equals
    /// prior AND prior was itself "0" (the engage demonstrably had no
    /// effect, so nothing is owed). A prior of "1" always commits — even
    /// when the read-back trivially confirms it's still "1" — because
    /// releasing there would immediately re-open the `if owned == 0` branch
    /// on the very next cycle while the flag is still present, turning the
    /// loop level-triggered (re-engaging every cycle) instead of
    /// edge-triggered. Confirmed empirically: comparing the read-back to
    /// prior alone, without the `prior == "0"` guard, makes the loop
    /// re-`mkdir`/write/write-pmset/release every single cycle once prior is
    /// already "1" — exactly the "re-asserting every cycle" this loop's
    /// edge-triggering exists to avoid.
    /// The loop body, unwrapped. Split out from `watchdogCommand` purely so
    /// tests can inspect its plain text directly — `watchdogCommand` wraps
    /// this in one more layer of quoting (see its own doc comment for why),
    /// which would otherwise turn every structural check below into a
    /// fragile assertion about escaped-of-escaped text.
    /// The `read_disabled` shell function text, shared verbatim by the loop
    /// body and `repairCommand`. Prints `0`/`1` on success; prints NOTHING
    /// and returns non-zero on any failure — `pmset -g` itself failing
    /// (checked via `$(...) ||`, i.e. the command substitution's own exit
    /// status, not by inferring from empty output) or an unparseable value.
    /// CRITICAL 1 of the review that added this: `repairCommand` used to
    /// pipe `pmset -g` straight into `awk` and let the `END{if (!f) print
    /// 0}` block mask a failing `pmset` as a confident "0", which let repair
    /// skip a restore and delete the only record of a real, still-live
    /// `disablesleep`. Defining this ONE helper and reusing it in both
    /// places (rather than a second inline pipeline) is what keeps them from
    /// ever diverging on that classification again.
    static func readDisabledFunction(pmsetPath: String) -> String {
        let pmset = ClaudeHooks.shellSingleQuoted(pmsetPath)
        return """
        read_disabled() {
            out=$(\(pmset) -g 2>/dev/null) || return 1
            v=$(printf '%s\\n' "$out" | awk '/SleepDisabled/{print $2; f=1; exit} END{if (!f) print 0}')
            case "$v" in
              0|1) printf '%s' "$v" ;;
            esac
          }
        """
    }

    static func watchdogLoopBody(
        flagPath: String,
        appPID: Int32,
        leasePath: String,
        pmsetPath: String = "/usr/bin/pmset",
        pollInterval: TimeInterval = 2,
        heartbeatPath: String = "/dev/null"
    ) -> String {
        let flag = ClaudeHooks.shellSingleQuoted(flagPath)
        let lease = ClaudeHooks.shellSingleQuoted(leasePath)
        let debt = ClaudeHooks.shellSingleQuoted(leasePath + "/debt")
        let debtTmp = ClaudeHooks.shellSingleQuoted(leasePath + "/debt.tmp")
        let pmset = ClaudeHooks.shellSingleQuoted(pmsetPath)
        let heartbeat = ClaudeHooks.shellSingleQuoted(heartbeatPath)
        return """
        \(readDisabledFunction(pmsetPath: pmsetPath))
          do_write() {
            \(pmset) -a disablesleep "$1" >/dev/null 2>&1
          }
          app_start=$(ps -o lstart= -p \(appPID) 2>/dev/null)
          watchdog_start=$(ps -o lstart= -p $$ 2>/dev/null)
          owned=0
          prior=
          while kill -0 \(appPID) 2>/dev/null &&
                [ -n "$app_start" ] &&
                [ "$(ps -o lstart= -p \(appPID) 2>/dev/null)" = "$app_start" ]; do
            echo . >> \(heartbeat)
            if [ -e \(flag) ]; then
              if [ "$owned" -eq 0 ]; then
                p=$(read_disabled)
                # IMPORTANT 2: every field the Swift loader requires must be
                # validated BEFORE the lease is taken and BEFORE pmset is
                # touched — a failed `date` here would otherwise commit a
                # debt with an empty setAt, which SleepWatchdogDebt.load
                # rejects, stranding the very prior value repair needs.
                # Non-emptiness alone is not enough: the loader parses setAt
                # as a TimeInterval, so a `date` on PATH that exits 0 but
                # prints something nonnumeric (broken or hostile) must be
                # rejected too, not just an empty one — reset to empty here
                # so the same "$setAt" -n check below catches both.
                setAt=$(date +%s 2>/dev/null)
                case "$setAt" in ''|*[!0-9]*) setAt= ;; esac
                if [ -n "$p" ] && [ -n "$watchdog_start" ] && [ -n "$setAt" ] && mkdir \(lease) 2>/dev/null; then
                  if printf 'app_pid=%s\\nwatchdog_pid=%s\\nwatchdog_start=%s\\nprior=%s\\nsetAt=%s\\n' \(appPID) "$$" "$watchdog_start" "$p" "$setAt" > \(debtTmp) 2>/dev/null &&
                     mv \(debtTmp) \(debt) 2>/dev/null; then
                    do_write 1
                    v=$(read_disabled)
                    if [ "$v" = "$p" ] && [ "$p" = "0" ]; then
                      rm -rf \(lease)
                    else
                      owned=1; prior=$p
                    fi
                  else
                    rm -rf \(lease)
                  fi
                fi
              fi
            elif [ "$owned" -eq 1 ]; then
              do_write "$prior"
              v=$(read_disabled)
              if [ "$v" = "$prior" ]; then
                owned=0
                rm -rf \(lease)
              fi
            fi
            sleep \(pollInterval)
          done
          if [ "$owned" -eq 1 ]; then
            do_write "$prior"
            v=$(read_disabled)
            if [ "$v" = "$prior" ]; then
              rm -rf \(lease)
              rm -f \(flag)
            fi
          else
            rm -f \(flag)
          fi
        """
    }

    /// The full command handed to `osascript`.
    ///
    /// `/bin/sh` on macOS is bash 3.2 (frozen there for licensing reasons),
    /// which has a well-known quirk: `$$` inside a backgrounded `( ... )`
    /// subshell reports the OUTER invoking shell's pid, not the subshell's
    /// own forked one — and bash 3.2 predates `$BASHPID`, which would
    /// otherwise give the real one. So the loop body isn't backgrounded as a
    /// bare subshell; it's handed as a single-quoted argument to a NESTED
    /// `sh -c`, entered via `exec` (which replaces the process image without
    /// forking again) so that nested shell's own `$$` — evaluated fresh at
    /// ITS startup — correctly reports the real, already-forked, background
    /// process's pid. That pid is what `watchdog_pid` in the debt record
    /// identifies, and what the detector's liveness check is bound to.
    static func watchdogCommand(
        flagPath: String,
        appPID: Int32,
        leasePath: String,
        pmsetPath: String = "/usr/bin/pmset",
        pollInterval: TimeInterval = 2,
        heartbeatPath: String = "/dev/null"
    ) -> String {
        let body = watchdogLoopBody(
            flagPath: flagPath, appPID: appPID, leasePath: leasePath, pmsetPath: pmsetPath,
            pollInterval: pollInterval, heartbeatPath: heartbeatPath)
        return "exec sh -c \(ClaudeHooks.shellSingleQuoted(body)) </dev/null >/dev/null 2>&1 &"
    }

    /// Escapes a shell command for embedding in an AppleScript string literal.
    /// Backslashes first: escaping quotes first would then double-escape the
    /// backslashes this step introduces.
    static func appleScriptEscaped(_ command: String) -> String {
        command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    public func start(appPID: Int32) -> SleepSettingResult {
        // kill(0, .) signals the caller's whole process group and kill(-1, .)
        // signals every process the caller may reach — a non-positive pid
        // would let the loop poll indefinitely against the wrong target.
        guard appPID > 0 else {
            return .failed("Refusing to start the sleep watchdog for pid \(appPID).")
        }

        // Best-effort: creates the PARENT of the lease directory only, so
        // the very first engagement in a fresh install doesn't fail just
        // because "Let It Brew/" doesn't exist yet. Never pre-creates the lease
        // directory itself — only the shell loop's own atomic `mkdir` may
        // do that, or the exclusivity guarantee is void.
        try? FileManager.default.createDirectory(
            at: leaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let command = Self.watchdogCommand(
            flagPath: flagURL.path, appPID: appPID, leasePath: leaseURL.path)
        return runAdministratorScript(command, failureFallback: "The sleep watchdog could not be started.")
    }

    /// Builds the one-shot (non-looping) shell command `letitbrew repair` runs,
    /// under administrator privileges, to clear a lease whose owning
    /// watchdog loop is provably dead.
    ///
    /// Every part of this decision is re-derived HERE, from scratch, the
    /// instant this text actually executes — never handed in from an
    /// earlier Swift-side classification (that's the exact defect three
    /// prior attempts each got wrong in a different direction). `do shell
    /// script ... with administrator privileges` blocks on the OS password
    /// prompt, which can sit open for an arbitrary time; anything decided
    /// before that prompt returns can be stale by the time this script
    /// finally runs — the debt file's own content can even have changed.
    /// So this script reads the debt file itself, reads the live `pmset`
    /// value itself (via the SAME status-aware `read_disabled` the watchdog
    /// loop itself uses — enabled/disabled/unreadable from `pmset`'s own
    /// exit status, never inferred from empty output), and checks watchdog
    /// liveness itself, immediately before ever touching anything.
    ///
    /// - CASE A — the live value is unreadable: refuse, delete nothing. The
    ///   live state can't be trusted, so nothing downstream of it can be
    ///   either. Checked first, before the debt is even parsed.
    /// - CASE B — the debt parses (`watchdog_pid`, `watchdog_start`, and
    ///   `prior` were all recovered): a live owner (`kill -0` on the
    ///   recorded pid AND a matching `ps -o lstart=` — the same identity
    ///   binding used everywhere else in this file, not a bare `kill -0`
    ///   that a reused pid could fool) always refuses; it's in use. With no
    ///   live owner: if the live value already equals the recorded prior,
    ///   nothing is owed — clear the lease. Otherwise write the prior value,
    ///   confirm with a read-back, and only clear the lease once that
    ///   read-back confirms — any failure along the way keeps the lease
    ///   rather than discarding the only record of what's owed.
    /// - CASE C — the debt does NOT parse: there is no prior to restore to.
    ///   Live 0 is already the safe state, so nothing can be owed — clear
    ///   the lease. Live 1 can't be told apart from "the user set this by
    ///   hand" — refuse, and name the manual recovery command.
    static func repairCommand(
        leasePath: String, pmsetPath: String = "/usr/bin/pmset"
    ) -> String {
        let lease = ClaudeHooks.shellSingleQuoted(leasePath)
        let debt = ClaudeHooks.shellSingleQuoted(leasePath + "/debt")
        let pmset = ClaudeHooks.shellSingleQuoted(pmsetPath)
        return """
        \(readDisabledFunction(pmsetPath: pmsetPath))
        watchdog_alive() {
            kill -0 "$1" 2>/dev/null && [ "$(ps -o lstart= -p "$1" 2>/dev/null)" = "$2" ]
          }
        live=$(read_disabled)
        if [ -z "$live" ]; then
          echo 'letitbrew repair: could not read pmset -g; disablesleep state is unknown. Refusing to touch anything.' >&2
          exit 1
        fi
        watchdog_pid=
        watchdog_start=
        prior=
        if [ -f \(debt) ]; then
          while IFS='=' read -r field_key field_value || [ -n "$field_key" ]; do
            case "$field_key" in
              watchdog_pid) watchdog_pid=$field_value ;;
              watchdog_start) watchdog_start=$field_value ;;
              prior) prior=$field_value ;;
            esac
          done < \(debt)
        fi
        case "$watchdog_pid" in ''|*[!0-9]*) watchdog_pid= ;; esac
        [ -n "$watchdog_pid" ] && [ "$watchdog_pid" -eq 0 ] && watchdog_pid=
        case "$prior" in 0|1) ;; *) prior= ;; esac
        if [ -n "$watchdog_pid" ] && [ -n "$watchdog_start" ] && [ -n "$prior" ]; then
          if watchdog_alive "$watchdog_pid" "$watchdog_start"; then
            echo "letitbrew repair: lease is held by a live watchdog (pid $watchdog_pid); refusing -- it is in use." >&2
            exit 1
          fi
          if [ "$live" = "$prior" ]; then
            rm -rf \(lease)
            exit 0
          fi
          \(pmset) -a disablesleep "$prior" >/dev/null 2>&1
          v=$(read_disabled)
          if [ -z "$v" ] || [ "$v" != "$prior" ]; then
            echo 'letitbrew repair: could not confirm the disablesleep restore to the recorded prior value; leaving the lease in place.' >&2
            exit 1
          fi
          rm -rf \(lease)
          exit 0
        fi
        if [ "$live" = "0" ]; then
          rm -rf \(lease)
          exit 0
        fi
        echo 'letitbrew repair: this lease record could not be read, so it is unknown whether disablesleep=1 is something you set or something we set and lost the record of. Refusing to change it automatically -- if you are sure it is safe, run: sudo pmset -a disablesleep 0' >&2
        exit 1
        """
    }

    /// Runs `repairCommand(leasePath:)` with administrator privileges. Takes
    /// no classification from the caller on purpose — see that function's
    /// doc comment for why the whole decision must be re-derived inside the
    /// privileged shell rather than passed in. Should not be called against
    /// a lease with a KNOWN live owner (`.held`); callers gate on
    /// `SleepWatchdogDebtCheck.status(at:)` first and only reach here for
    /// `.orphaned` or `.unreadable` — but even so, this re-checks liveness
    /// itself before deleting anything, since that classification can be
    /// stale by the time the administrator prompt returns.
    public func repairOrphanedLease() -> SleepSettingResult {
        let command = Self.repairCommand(leasePath: leaseURL.path)
        return runAdministratorScript(command, failureFallback: "The lease could not be repaired.")
    }

    /// Shared `osascript ... with administrator privileges` runner behind
    /// both `start(appPID:)` and `repairOrphanedLease()`: same process
    /// plumbing, same cancellation classification, only the shell command
    /// and the fallback failure message differ.
    private func runAdministratorScript(_ command: String, failureFallback: String) -> SleepSettingResult {
        let script = "do shell script \"\(Self.appleScriptEscaped(command))\" "
            + "with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        let errorPipe = Pipe()
        process.standardError = errorPipe

        do {
            try process.run()
            let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            if process.terminationStatus == 0 { return .applied }

            let stderr = String(decoding: errorData, as: UTF8.self)
            if Self.isUserCancelledAuthorization(stderr: stderr) { return .cancelled }
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(trimmed.isEmpty ? failureFallback : trimmed)
        } catch {
            return .failed("Could not run the command.")
        }
    }
}
