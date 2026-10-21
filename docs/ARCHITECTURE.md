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
HookReducer.reduce(...)           → .set(working|waiting|idle) or .end
  ↓
SessionStorage                    → one JSON record per session, on disk
  ↓  the app polls, roughly once a second
Decision.decide(sessions, settings, power)
  ↓
hold or release
```

`HookReducer` maps individual lifecycle events, while `HookSessionUpdater`
reconciles related Claude parent and child records. They reduce every supported
adapter to **Working**, **Waiting**, or **Idle** (or remove a terminal record).
Waiting means the agent is blocked on the person: a question, or an approval
prompt that a hook proves is shown to them. Its detail token says which. It is
stored as `awaiting_input`, because pre-0.5 records used `waiting` with other
semantics and remain unsupported.

The common lifecycle mapping is:

- `SessionStart` maps to **idle, not working**, except `source=compact`, which
  follows the compaction rule below. A session that has never been
  prompted emits no further events, so treating it as working would hold the Mac
  awake for as long as that process lives. Claude's `SessionStart` is Idle only
  for `startup`, `resume`, and `clear`; any other or missing source returns no
  effect, so a source fired inside a running turn cannot release its hold.
- `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, and `SubagentStart` set
  **Working**.
- `PreCompact`, `PostCompact`, and `SessionStart(source=compact)` return no
  effect, preserving the prior state. Claude and Codex also compact at an idle
  prompt (`/compact`, and Claude's idle auto-compaction before the prompt cache
  expires) and emit `PreCompact` alone when a compact aborts; no `Stop` follows
  either. A compaction inside a turn stays Working until that turn's `Stop`.
  Claude's `PostCompact` with `trigger: manual` sets **Idle**: a manual compact
  runs only at the idle prompt, so it also clears a turn an interrupt left
  Working. A parent Working only because its `Stop` reported background tasks
  keeps that hold.
- Codex's `Interrupt` sets **Idle**. It is the only hook an Esc-cancelled Codex
  turn fires.
- `Stop` and an `idle_prompt` `Notification` set **Idle**. Idle rows are hidden
  and stop contributing to the hold on the next one-second app poll. `Stop`
  with nonempty `background_tasks` remains **Working**; `StopFailure` is Idle.
- Question tools (`AskUserQuestion` for Claude, `request_user_input` for Codex,
  and Copilot's `ask_user` family) set **Waiting** at `PreToolUse`; the answer's
  `PostToolUse` sets Working again. OpenCode and Pi input requests and
  Copilot and OpenCode permission requests also set Waiting.
- Claude's `permission_prompt` `Notification` sets **Waiting**. Claude sends it
  only after its prompt has waited on screen for about six seconds, so a
  request another hook or auto mode settles never sends it. `PermissionRequest`
  for Claude and Codex returns no effect: both run it before another hook, auto
  mode, or Codex's auto-reviewer decides, so it does not prove a person is
  being asked.
- `SubagentStop` and `SessionEnd` remove the addressed active record. For Claude
  and Codex, a parent `SessionEnd` also removes its children. Codex can omit a
  child's `SubagentStop`, so a Codex parent `Stop` or `Interrupt` also removes children that
  sent no hook since the turn's `UserPromptSubmit`; a child heard during the
  turn may still be running and waits for a later `Stop` or `SessionEnd`. The
  latest prompt starts the turn even when an earlier turn ended without a hook.
  The parent records that cutoff as `stale_child_cutoff`; session scans and
  later child hooks honor it, so an interrupted cleanup cannot leave those
  children Working. `SubagentStop` can make a
  parent still Working from `Stop` Idle when its explicit background-task
  snapshot reports no remaining work. Missing snapshots and parents with newer
  foreground activity retain their state.

Claude and Codex hook updates acquire a bounded family lock before any per-record lock.
This serializes terminal cleanup with child writes. The parent's existing
terminal marker rejects late child updates, including children not previously
seen, until a new session-start or prompt event reopens the parent. Other agents
keep their existing per-record update semantics. Session scans also honor the
parent terminal if child-file cleanup was interrupted. The optional numeric
`reopened_at` field preserves sub-second ordering after a proven terminal/reopen;
initial or legacy parent records have no such cutoff. Readers retain children
when a parent's state is missing or unreadable. The product remains hook-only;
no process polling, transcript inspection, or silence-based early release is
used to guess whether an interrupted Claude turn finished. A Waiting parent is
still inside its turn, so a Codex `Stop` or `Interrupt` from Waiting sweeps
silent children too. The sweep's turn start is the latest prompt whenever it is
known, because a wait and its answer move `stateChangedAt` inside the turn.

The hook CLI records the agent's process ID by walking its parents past shell
wrappers (`sh`, `bash`, `zsh`, `env`, and similar). The ID is presentation
only: it lets the menu bring the agent's app forward and hide a Waiting row
whose agent exited. It never affects the hold or eviction.

Each adapter's exact source-event vocabulary is frozen in
[AGENT-HOOK-CONTRACTS.md](AGENT-HOOK-CONTRACTS.md); unsupported source events do
not infer a state.

`Decision.decide()` is a pure function over sessions, settings, power state,
local input, and whether Let It Brew owns the current Low Power Mode. It is
where the battery floor and thermal release live. `PowerState.trusted` exists
so a *failed* IOKit read is never mistaken for "this machine has no battery" —
an untrusted reading must not bypass the battery floor.

A Waiting session releases the hold, with no grace period. Every question,
and every OpenCode and Pi wait, reports its answer with a hook, so those waits
never consult input. Approving a Claude or Copilot prompt fires no hook before
the approved tool runs, so for those approvals `WaitAnswerLatch` treats a key
press or click after the wait began as a possible answer: the session holds
again, and is shown as Working, until its next hook. Only input that went to
the session's own app counts: `FrontmostInputAttribution` credits each input to
the app in front when it happened, sampling the counters on every poll and on
every activation change, and the app is the one the menu brings forward for
that session. Typing in a chat therefore cannot answer a terminal's prompt. A
session whose app is unknown, as under tmux, falls back to input in any app.
The click that brings the app forward counts for it, because the app may act
on that first click. Only Claude's permission notification
also accepts input up to three seconds before it, because it arrives about six
seconds after its prompt and can land just after the answering keystroke; every
other wait is reported as its prompt appears, so the Enter that submitted the
turn never answers it. Input from the last half second waits for the next poll,
so the menu can report that it opened before its own opening click is judged. Pointer movement and scrolling never count; key
presses and clicks while Let It Brew's own menu is open, or the click that
opened it, are discarded by `OwnMenuInputFilter`, so checking the menu cannot
answer a wait. The times come from the HID system's per-event idle counters,
which need no permission; an unreadable counter keeps those approvals held. Because the
counters report only each kind's latest event, the latch keeps a wait answered
for its lifetime once any poll saw an answer. The worst case for a Claude
approval is the hold it kept before Waiting existed. An approval given from
another device while the lid is open has no local input and can still let the
Mac sleep before the approved tool finishes.

"Respect Low Power Mode" releases on Low Power Mode only when it is the
person's own. While Let It Brew's closed-lid switch is confirmed, `decide()`
ignores Low Power Mode on the current power source unless that source was
already in Low Power Mode before the switch; the daemon reports those sources
in its reply. While a request is in flight, and for three seconds after any
request completes or a connection that may have switched is replaced, it is
ignored too, because ProcessInfo can lag the change. Every other safety gate
still applies.

The app-level presentations are deliberately separate from the agent session
states:

| State | Meaning |
|---|---|
| **Keeping your Mac awake** | At least one local agent is Working, subject to safety gates. |
| **Agents are waiting for you** | No agent is Working, and at least one is Waiting; the Mac may sleep. |
| **Your Mac can sleep** | No observed local agent is Working or Waiting; Idle sessions are hidden. |
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
round-robin sessions across all supported agents. It covers independent record
identity, old-event/new-event ordering, selected-agent visibility, child-session
isolation, aggregate hold release only after the final Working session becomes
Idle, corrupt-record isolation, grouping, and presentation.

## Adaptive activity menu

Working and Waiting sessions become menu rows; Waiting rows show an orange
"Waiting for your answer" or "Needs your approval". A session keeps its row and
position as it moves between the two. Group badges count each, as in
"1 working · 2 waiting". Clicking a row whose agent process is known brings
forward the first regular app among the agent's ancestors (a terminal, editor,
or the Claude or Codex app). A terminal host that runs detached from its app,
such as iTerm2's server or Orca's terminal host, is matched instead by the app
bundle that holds its executable, outermost ancestor first.
Activation is app-level only: no Accessibility or Automation access is
requested, so a specific window or tab is not selected, and sessions under
tmux or screen have no reachable app.

One session in a full folder
path is a flat row; two or more in that same full path form a disclosure group.
The full standardized path is the grouping identity, so same-named folders at
different paths remain distinct.

On the first real loaded snapshot, the newest eligible multi-session repository
is initially expanded. After that, manual expansion remains stable while the
repository still has any Working sessions. An expanded group retains its header
when only one child remains; expanding another group collapses the current one.
Surviving sessions and repositories retain their presented order across polls;
new Working entries append, with recency deciding the initial and newcomer order.
Only user disclosure clicks animate layout. Hook updates do not animate the
scroll area. Snapshot freshness uses the time after records are loaded, while
async result ordering retains the read-start time.
Grouped children show the agent and project folder
instead of an internal session-ID fragment. Their accessibility labels include
eight-character session IDs that lengthen only as needed to disambiguate
collisions. They reuse the flat session-row layout, so logo, text, and timer
alignment do not gain indentation.

The activity viewport is capped at 302 points: one 54-point group header
plus four 60-point session rows and four 2-point gaps. One outer vertical scroll owns overflow; there
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

`PMSetDaemonSleepControl` makes the daemon's **only** system mutations:
`disablesleep`, and the per-source energy mode described below. It shells out
to `/usr/bin/pmset` and does nothing else.

### Low Power Mode with the lid closed

While a confirmed lid-closed hold is active, the lid is shut, and no external
display is attached, the app asks the daemon to switch every power source to
Low Power Mode. This is on by default and can be turned off under
**Settings → Power & Display → Closed lid**. The daemon accepts the request
only from a client that owns a lid-closed hold, so Low Power Mode is nested
inside it: releasing that hold, or disconnecting, releases it too.

Before writing anything, the daemon reads `pmset -g custom` and records each
source's exact energy mode — key (`powermode` on newer macOS, `lowpowermode`
on older) and value — in a second restore record beside the sleep debt. It
then writes `1` only to sources not already in Low Power Mode, and confirms the
result. A failed or partial switch is rolled back from that record. The last
release restores every recorded source exactly, then removes the record after
a read-back. Values, not names, are compared and restored, and each write uses
the name the live system reports, so a record survives macOS renaming the
setting. Launch reconciles a leftover record, and every later release or
handshake retries a failed restore. Upgrade and uninstall preparation retry it
too, but never block on it: the next daemon reconciles the same record.

Low Power Mode never gates `disablesleep`. A failure to switch or restore the
energy mode is reported in Settings, but cannot keep a Mac awake or block a
lid-closed hold. That is also why an unreadable energy-mode record is cleared
without guessing a value, where an unreadable sleep debt blocks.

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

The adapters are deliberately narrow and user-scoped: Claude Code uses
`~/.claude/settings.json`; Codex uses `~/.codex/hooks.json` or
`$CODEX_HOME/hooks.json`; OpenCode writes its one global plugin at
`~/.config/opencode/plugins/letitbrew.js` or
`$OPENCODE_CONFIG_DIR/plugins/letitbrew.js`; GitHub Copilot CLI uses
`~/.copilot/hooks/letitbrew.json` or `$COPILOT_HOME/hooks/letitbrew.json`; and
Pi uses `~/.pi/agent/extensions/letitbrew.ts` or
`$PI_CODING_AGENT_DIR/extensions/letitbrew.ts`.
The three JSON markers are adapter-specific and frozen: Claude uses
`__letitbrew_hook`, Codex `__letitbrew_codex_hook`, and Copilot
`__letitbrew_copilot_hook`. OpenCode and Pi own
only their named plugin/extension files. The versioned registry at
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
requires an explicit `/hooks` trust step; Let It Brew cannot approve it.
OpenCode is limited to its stable 1.x local runtime and preserves unrelated plugins.
Copilot's observational `ErrorOccurred` hook maps an explicit
`recoverable: false` payload to Idle. Recoverable or malformed error payloads
preserve the prior state because the same turn may continue. Let It Brew does
install Copilot `PreToolUse` and `PermissionRequest` hooks, but only as
observational lifecycle signals: their output is discarded and their commands
exit zero, so they cannot allow, deny, or block a Copilot action.

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
