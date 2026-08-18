# Architecture

Let It Brew installs a privileged background service that changes a system-wide
sleep setting. That is a lot of trust to ask for, so this document explains what
runs, what each piece is allowed to do, and how the app proves it is talking to
the right service.

## The pieces

| Target | Kind | Responsibility |
|---|---|---|
| `LetItBrewApp` | Xcode-only | SwiftUI/AppKit menu bar, settings, live I/O. |
| `LetItBrewAppCore` | SwiftPM library | Pure app policy and state machines. No I/O. |
| `LetItBrewCore` | SwiftPM library | Hooks, session records, power primitives. |
| `LetItBrewDaemon` | Xcode-only | The privileged launchd daemon executable. |
| `LetItBrewDaemonCore` | SwiftPM library | XPC protocol, hold coordination, sleep control. |
| `letitbrew` | SwiftPM executable | The CLI shim that agent hooks invoke. |

`LetItBrewApp` and `LetItBrewDaemon` are deliberately thin. Anything worth
testing lives in one of the three `*Core` libraries, which is why `swift test`
covers real behavior and not just plumbing. The tradeoff is explicit and it
matters: **`Sources/LetItBrewApp/` is not a SwiftPM target**, so `swift test`
never compiles or runs the live URLSession download, DMG operations, SwiftUI
confirmation flow, AppKit quit, or relaunch report. `xcodebuild` proves only
that those compile. See [ATTENDED-UAT.md](ATTENDED-UAT.md) for what covers them.

## How a session becomes an awake hold

```
agent lifecycle event
  ↓  agent runs the installed hook command
letitbrew hook <agent> <event>    (Sources/letitbrew)
  ↓  HookPayload parses the event from stdin
HookReducer.reduce(...)           → .set(working|idle) or .end
  ↓
SessionStorage                    → one JSON record per session, on disk
  ↓  the app polls, roughly once a second
Decision.decide(sessions, settings, power)
  ↓
hold or release
```

`HookReducer` is the whole state model, and it is small on purpose. It reduces
every supported adapter to only **Working** and **Idle** (or removes a terminal
record); there is no third permission or waiting state.

The common lifecycle mapping is:

- `SessionStart` maps to **idle, not working**, except `source=compact`, which
  maps to **Working**. A session that has never been
  prompted emits no further events, so treating it as working would hold the Mac
  awake for as long as that process lives.
- `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PreCompact`, `PostCompact`,
  and `SubagentStart` set **Working**.
- `Stop` and an `idle_prompt` `Notification` set **Idle**. Idle rows are hidden
  and stop contributing to the hold on the next one-second app poll. `Stop`
  with nonempty `background_tasks` remains **Working**; `StopFailure` is Idle.
- `PermissionRequest` and `permission_prompt` notifications return no effect,
  preserving the prior Working or Idle state. Permission is not a third session
  state.
- `SubagentStop` and `SessionEnd` remove the addressed active record.

Each adapter's exact source-event vocabulary is frozen in
[AGENT-HOOK-CONTRACTS.md](AGENT-HOOK-CONTRACTS.md); unsupported source events do
not infer a state.

`Decision.decide()` is a pure function over sessions, settings, and power state.
It is where the battery floor and thermal release live. `PowerState.trusted`
exists so a *failed* IOKit read is never mistaken for "this machine has no
battery" — an untrusted reading must not bypass the battery floor.

The three app-level presentations are deliberately separate from the two agent
session states:

| State | Meaning |
|---|---|
| **Keeping your Mac awake** | At least one local agent is Working, subject to safety gates. |
| **Your Mac can sleep** | No observed local agent is Working; Idle sessions are hidden. |
| **Let It Brew is paused** | Sessions are still observed, but Let It Brew owns no hold. |

## Concurrent session storage and observation

`SessionStorage` writes one atomic JSON record per active session. Concurrent
read/modify/write updates for the same session use a bounded per-session lock;
different session IDs do not share one global mutation lock. Session IDs are
untrusted, so changed, empty, or truncated filename stems receive a deterministic
digest suffix. That keeps common sanitization collisions from merging separate
records and gives the record and lock the same bounded, allowlisted name.

Terminal updates commit an ordered tombstone at the active record path before
moving it under the secured `.locks` directory. The tombstone prevents an older
concurrent event from resurrecting a completed session, while keeping terminal
entries out of the app's one-second active-record scan. A newer legitimate event
for the same ID replaces the tombstone under the same lock.

The hook command deliberately returns success even when decoding, locking, or
updating fails. Agent hooks are in the user's critical path, so a Let It Brew
storage problem must not block the agent. This fail-open CLI boundary means the
event may be missed; it does not bypass the app's battery, thermal, pause, power,
or daemon safety gates and is not evidence that the hold changed.

The deterministic automated pressure harness qualifies 1, 10, 15, 50, and 100
round-robin sessions across all five agents. It covers independent record
identity, old-event/new-event ordering, selected-agent visibility, child-session
isolation, aggregate hold release only after the final Working session becomes
Idle, corrupt-record isolation, grouping, and presentation.

## Adaptive activity menu

Only Working sessions become menu rows. One Working session in a full folder
path is a flat row; two or more in that same full path form a disclosure group.
The full standardized path is the grouping identity, so same-named folders at
different paths remain distinct.

On the first real loaded snapshot, the newest eligible multi-session repository
is initially expanded. After that, manual expansion remains stable while the
repository still has at least two Working sessions, and expanding another group
collapses the current one. Grouped children start with eight-character session
IDs and lengthen only as needed to disambiguate collisions. They reuse the flat
session-row layout, so logo, text, and timer alignment do not gain indentation.

The activity viewport is capped at 294 points: at most one 54-point group header
plus four 60-point session rows. One outer vertical scroll owns overflow; there
are no nested per-group scroll regions.

## Two kinds of hold

**Open lid** uses an ordinary IOKit power assertion
(`LetItBrewCore/PowerAssertions.swift`), owned by the app process. If the app
crashes, macOS releases it automatically, exactly as it would for any other app.
There is nothing to clean up.

**Closed lid** cannot use an assertion at all — clamshell sleep ignores power
assertions entirely. The only thing that works is the system-wide
`SleepDisabled` setting, and only a privileged process may write it. That is the
entire reason the daemon exists.

Writing a global setting creates an obligation: it has to be put back, even if
the app crashes, the daemon is killed, or the Mac reboots mid-hold. So the daemon
records a **sleep debt** — the exact prior value plus a timestamp — under
`/Library/Application Support/LetItBrew/` before it changes anything. On
`RunAtLoad`, the daemon reconciles that debt before serving any XPC request.

The rule that follows from this, and that every code path must respect:

> Restore the exact recorded `SleepDisabled` baseline. An unreadable value is an
> error, never `0`. Your Mac may have intentionally started with another value.

`PMSetDaemonSleepControl` is the daemon's **only** system mutation. It shells out
to `/usr/bin/pmset` and does nothing else.

## Why the app trusts the daemon (and vice versa)

An app that asks a root process to change your sleep settings has to prove, both
ways, that it is talking to the intended peer. Three gates do that.

**1. Location and team.** `BackgroundServiceEligibility` requires the app to be
running from exactly `/Applications/Let It Brew.app` and to carry Apple Developer
Team `MV2UL94MDC`. A copy in Downloads, on the mounted DMG, or inside a subfolder
is refused before an `SMAppService` is even constructed. This is why the README
insists on that exact path.

**2. Signature, not path.** `RuntimeSigningIdentity` validates the live code
signature and reads the Team ID from signing metadata, falling back to the
validated leaf certificate's Organizational Unit for entitlement-free tools.
It reads the running code object, not the executable at a path — during an update
the path may already name a replacement bundle while launchd is still serving the
previous image.

**3. Handshake before every hold.** The app handshakes on protocol version,
marketing version, build, and exact Code Directory hash
(`LetItBrewDaemonBuildIdentity`) before requesting anything. `protocolVersion`
increments only for an incompatible wire change. A stale daemon is replaced only
after that same authenticated daemon proves it is reconciled and has quiesced.

There is deliberately **no `SMAppService.status` read anywhere in the app.**
Status reads are not passive — they have side effects on the Background Task
Management record. Daemon existence is always established by asking the
authenticated daemon itself. This is not a style preference; treating an
unreachable connection or a disabled preference as proof of absence has caused
real regressions, most notably a *stranded* daemon: registered and running while
the closed-lid preference reads off.

## Hook installation

The five adapters are deliberately narrow and user-scoped: Claude Code uses
`~/.claude/settings.json`; Codex uses `~/.codex/hooks.json` or
`$CODEX_HOME/hooks.json`; Cursor uses `~/.cursor/hooks.json`; OpenCode writes
its one global plugin at `~/.config/opencode/plugins/letitbrew.js` or
`$OPENCODE_CONFIG_DIR/plugins/letitbrew.js`; and GitHub Copilot CLI uses
`~/.copilot/hooks/letitbrew.json` or `$COPILOT_HOME/hooks/letitbrew.json`.
The four JSON markers are adapter-specific and frozen: Claude uses
`__letitbrew_hook`, Codex `__letitbrew_codex_hook`, Cursor
`__letitbrew_cursor_hook`, and Copilot `__letitbrew_copilot_hook`. OpenCode owns
only its named plugin. The versioned registry at
`~/Library/Application Support/LetItBrew/agent-hook-targets.json` records the
exact selected target, so later environment changes cannot redirect an owned
connection.

Three constraints shape that code:

- **Absolute path, never a PATH lookup.** The installed command resolves the CLI
  inside the app bundle. A stale hook left behind after the app is deleted would
  otherwise let any `letitbrew` on `PATH` run on every tool call.
- **Only the events `HookReducer` maps.** Nothing speculative.
- **Unparseable configuration is left alone.** An unreadable file, a non-object
  root, or a `hooks` value that isn't the expected shape is reported as **Action
  needed** rather than rewritten. Other tools' JSON structure and values are
  preserved, although JSON adapters may reserialize formatting.

Claude requires workspace trust before its hooks run. Codex additionally
requires an explicit `/hooks` trust step; Let It Brew cannot approve it. Cursor
maps desktop Agent and local CLI events through its user hooks. OpenCode is
limited to its stable 1.x local runtime and preserves unrelated plugins.
Copilot's observational `ErrorOccurred` hook maps an explicit
`recoverable: false` payload to Idle. Recoverable or malformed error payloads
preserve the prior state because the same turn may continue. Let It Brew does
not install Copilot's decision-capable `PreToolUse` or `PermissionRequest`
hooks. The selected Copilot hooks themselves are silent and exit zero.

## Updating

The one-click update is a staged, verified, same-volume atomic transaction. The
constraint that drives its shape:

> Never overwrite a running signed executable. Modifying an existing Mach-O
> inode invalidates its code signature, and later launches can be killed by the
> OS.

So the update stages the new app at a fresh path, verifies the signed DMG and
published SHA-256, safely transitions the background service, renames atomically,
and relaunches. If verification or the service transition cannot be proven safe,
nothing is replaced. A post-swap failure rolls back where possible and retains
recovery evidence rather than discarding it.

## Uninstall ordering

Uninstall runs three hard gates — release holds, reconcile daemon, unregister
daemon — before **any** removal, and re-runs them immediately before acting. If
either the sleep-baseline restoration or the service teardown cannot be done
safely, uninstall stops and removes nothing.

Everything after those gates (agent hooks, Launch at Login, user data,
preferences, moving the app to the Trash) is best-effort: each step runs even if
an earlier one failed, and failures accumulate into a report rather than aborting
the run. Leaving a half-uninstalled app is better than leaving a Mac that cannot
sleep.

## Testing boundary

| Layer | Covered by |
|---|---|
| `*Core` libraries | `swift test` |
| Release/update shell scripts | `scripts/tests/*.sh`, isolated fixtures |
| `LetItBrewApp` live I/O | Attended UAT only — see [ATTENDED-UAT.md](ATTENDED-UAT.md) |
| Signing, notarization, Gatekeeper | Manual release gates — see [../SIGNING.md](../SIGNING.md) |

A green `swift test` does not prove the live uninstall or update paths ran, and
`BUILD SUCCEEDED` does not prove they work. Treat any claim otherwise as a bug in
the claim.
