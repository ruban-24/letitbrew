# Attended UAT

Maintainer checklists for the paths that cannot be automated. These are not
pull-request checks — they need a signed install, physical access to the Mac, and
a reinstall between runs.

The reason they exist is in [ARCHITECTURE.md](ARCHITECTURE.md#testing-boundary):
`Sources/LetItBrewApp/` is not a SwiftPM target, so `swift test` never executes
the live URLSession download, DMG/Gatekeeper operations, model actions, SwiftUI
confirmation behavior, AppKit quit, result-directory polling, or relaunch report.
`xcodebuild` proves those compile. This document is the evidence that they run.

If a safety or power test fails, stop with physical access to the Mac, preserve
the original `SleepDisabled` baseline, record the exact reproduction, and stop
using the affected feature until it is understood.

## v1.0.0 release scope

This release adds three things: closed-lid Low Power Mode in the daemon, a
Waiting state with an input check, and app-level session activation. It also
redesigns the menu and Settings and carries the unpublished v0.8.4 fixes, so
run the v0.8.4 release scope below with this build too.
Record version 1.0.0, build 39, the full commit, and artifact hashes. Before
starting, record `pmset -g custom | grep -E 'Power:|powermode'` and
`pmset -g | grep SleepDisabled`. Both must read back identically after every
case below.

### Closed-lid Low Power Mode

1. With the default setting on, on battery, start long Working agent work,
   close the lid with no external display, and wait 30 seconds. Over SSH or
   from another Mac with screen sharing, confirm every source reports `1` and
   the work continues.
2. Open the lid while work continues. Confirm each source returns to its
   recorded value within a few seconds and the Mac stays awake.
3. Close the lid again, then let the work finish. Confirm the energy mode is
   restored before the Mac sleeps: wake it and compare.
4. Repeat on the charger, and with one source already in Low Power Mode, and
   with `powermode 2` (High Power) on a Mac that offers it. Each exact prior
   value must come back.
5. With an external display attached and the lid closed, confirm Low Power Mode
   is not switched.
6. Turn on **Respect Low Power Mode**. Confirm closed-lid work keeps holding
   while Let It Brew's own switch is active, and that turning on Low Power
   Mode yourself with the lid open still releases the hold. With Low Power
   Mode set to "Only on Battery", start closed-lid work on the charger, then
   unplug: the hold must release, because battery Low Power Mode is yours.
7. Turn the closed-lid Low Power Mode setting off and confirm nothing is
   switched.
8. While switched, force-quit Let It Brew. Confirm the daemon restores the
   energy mode and `SleepDisabled` when the connection drops.
9. While switched, `sudo launchctl kickstart -k` the daemon. Confirm launch
   reconciliation restores the energy mode, and that the app reconnects and
   switches again only while the lid is still closed.
10. Uninstall while switched. Confirm the energy mode is restored before the
    service is unregistered.

### Waiting and the input check

1. Claude: trigger a permission prompt for a long command and leave it. After
   about six seconds the row shows orange "Needs your approval" and the header
   reads "Agents are waiting for you". Close the lid and confirm the Mac sleeps.
2. Claude: approve a prompt after the six-second notification, for a command
   that runs several minutes, then walk away with the lid open. Confirm the row
   shows Working and the Mac stays awake until the command finishes.
3. Claude: approve within six seconds. Confirm the session never shows Waiting.
4. Claude and Codex: ask a question (`AskUserQuestion`, `request_user_input`).
   Confirm Waiting with no input, then Working after answering.
5. Codex: trigger an approval with and without `approvals_reviewer =
   auto_review`. Confirm the session stays Working and holds in both.
6. Copilot, OpenCode, and Pi: confirm their questions and approvals show
   Waiting, release without input, and resume after an answer. Copilot: allow
   a long command with an allow rule or "approve for session", run it again,
   and confirm it stays Working with no input. Pi: open a dialog at the idle
   prompt and confirm no Waiting row appears.
7. Quit an agent that is Waiting without answering, before and after typing in
   its app. Confirm its row disappears and the Mac may sleep.
8. With a Claude approval Waiting, move the pointer, scroll, open and close Let
   It Brew's menu, and type in another app, such as a chat. Confirm the row
   stays Waiting and the Mac may still sleep. Then type one key in the
   session's own terminal or app and confirm the row shows Working and holds.
   Repeat with the session under tmux: input in any app counts there. With a
   question Waiting, type in the session's app without answering and confirm
   the row stays Waiting. Approve with Enter, then open Let It Brew's menu
   within a second, and confirm the row shows Working and holds.
9. Approve a long Claude command, then quit and relaunch Let It Brew while it
   runs. Confirm the row shows Working and the Mac stays awake.
10. Copilot: deny an approval, dismiss a question, and press Esc during a
    wait. Confirm each session returns to Idle or Working and does not stay
    Working after the turn has ended. Record any case that has no hook.
11. In the signed, Finder-launched app with no Input Monitoring permission,
    confirm key presses and clicks are still observed (step 8) and that no
    permission prompt appears.

### Session jump

Click a Working and a Waiting row for sessions in Terminal, iTerm2 (including
with its session-restoration server), Ghostty, Orca (whose terminal host runs
detached from the app), VS Code's terminal, the Claude desktop app, and the
Codex app. Each should bring its app forward with no permission prompt. Before
release, a dry run of the shipping lookup against live sessions resolved
Ghostty, Orca, and the Codex app, including Codex nested under the ChatGPT
app's bundled tools inside an Orca terminal, and a background process could
activate an app on this macOS; one click in the signed app still confirms the
popover path. Under tmux, confirm the click does nothing and nothing
fails. Confirm rows recorded before this release, which have no process ID, are
not clickable.

### Menu and Settings layout

In light and dark mode, with the signed app:

1. With one Waiting session and Working sessions in a shared folder and on
   their own, open the menu. Confirm **Needs You** lists the waiting session
   first, **Working** follows, folder rows do not repeat the folder name, and
   the header reads, for example, "2 agents are working · 1 waiting". The
   folder icon and name line up with the logos and names of sessions on their
   own rows, and an expanded folder's sessions keep that same left edge inside
   one shaded, rounded block. A
   Claude session left with only background shells reads **Running in
   background**.
2. Hover a session: it highlights only if it can be brought forward, and its
   active time gives way to the eye button. Stop watching one session from
   the eye button and another from the right-click menu. With a Claude
   approval Waiting, click its row, then right-click it and choose **Show
   Session’s App**: both bring the app forward, and the row must stay
   Waiting, because clicks in Let It Brew's menu never count as an answer.
3. With more sessions than fit, confirm the list scrolls inside the menu and
   the footer stays visible.
4. Open Settings with ⌘, from the menu. Confirm the toolbar tabs General,
   Agents, Power, Closed Lid, and About, that the window title follows the
   tab, and that each pane fits without clipping. Run **Check for Updates…**
   from General.
5. On Agents, confirm the Claude Code, Codex, OpenCode, Copilot, and Pi marks
   are legible in dark mode and each row shows its connection status.
6. On Closed Lid, turn the closed-lid setting off and on, and confirm the
   helper status and Low Power Mode setting follow it.

### Background work after a Claude turn ends

Use a cheap model, for example `claude --model haiku`, in a fresh Claude Code
session for each case. Read the session's record under
`~/Library/Application Support/LetItBrew/sessions` and `pmset -g assertions`
to confirm the hold, and the menu to confirm the row.

1. Ask Claude to run `sleep 900` with `run_in_background` and reply without
   waiting. After it replies, the record is Working with `last_event: Stop`
   and `detail: background-shell`, the menu lists it as **Running in
   background**, and the Mac is held. Kill the sleep and send any prompt: the next Stop makes it Idle.
2. Repeat case 1 but leave the sleep running for over an hour (or, for a
   faster check, confirm from the status output that the reason becomes
   "background shell hold expired" once `updated_at` is an hour old). The
   hold releases while the row stays listed as **In background · Mac can
   sleep** until the next hook.
3. Ask Claude to use the Agent tool with model haiku to start `sleep 800` in
   the background and return. After the parent replies, the child record is
   gone, the parent is Working with `detail: background-shell`, and killing
   the sleep plus one more prompt makes it Idle.
4. Ask Claude to start a background Agent, then stop that agent with
   TaskStop before it finishes, and let the turn end. The child record is
   deleted by the parent's Stop and the parent is Idle.
5. Start a Codex session, let it work, and `kill -9` the Codex process. On
   the next poll the row disappears and the hold releases. Repeat with a
   Claude session: same result.

## v0.8.4 release scope

v0.8.4 fixes Claude and Codex sessions left Working by compaction, interrupts,
and missing subagent completion, and finds Codex bundled in newer desktop apps.
Record version 0.8.4, build 35, the full commit, and artifact hashes with the results. In the
signed app, run the Claude and Codex cases below, including idle compaction,
manual `/compact`, Codex Esc after approving the new `Interrupt` hook in
`/hooks`, and Codex subagents, with another session running to confirm it
remains protected. Verify that normal long-running work still holds the Mac
awake. With only the ChatGPT desktop app's bundled Codex available, confirm
Agents settings verifies already-trusted Codex hooks. Record Claude Esc
interrupts separately; Claude sends no hook for them, so they stay Working.
Run the signed-artifact and download-channel checks on the final release.
Power, daemon, login-item, and updater code are unchanged.

## v0.8.3 release scope

v0.8.3 fixes Claude parent/child completion and cleanup.
Record version 0.8.3, build 34, the full commit, and artifact hashes with the results. Exercise the
Claude completion, session-end, and resume cases below in the signed app, with
another Claude session running to confirm it remains protected. Verify that
normal long-running work still holds the Mac awake. Record interruption and
still-running monitor cases separately; this patch does not claim to resolve
missing completion hooks. Run the signed-artifact and download-channel checks
on the final release. Power, daemon, login-item, and updater code are unchanged.

## v0.8.2 release scope

v0.8.2 keeps the Launch at login setting's layout stable during registration,
failure, and retry. Record version 0.8.2, build 33, the full commit, and artifact
hashes with the results. In Settings → General, enable and disable Launch at
login: the switch and Closed lid section must remain in place while progress
appears beside the switch. Restore the original login preference after testing.
In the isolated native fixture, simulate registration failure, open the error
popover, and invoke Open Login Items; the form must stay in place and the
recovery action must run. Repeat the layout regression in light and dark mode.
The registration, power, daemon, agent-hook, and updater implementations are
unchanged. Run the signed-artifact and download-channel checks on the final
release, and smoke-test its Settings window before publication.

## v0.8.1 release scope

v0.8.1 stabilizes the activity menu during concurrent hook updates and fixes a
snapshot-read timing race. Record version 0.8.1, build 32, the full commit, and
artifact hashes with the results. With five or more Working Claude sessions,
scroll down and alternate tool activity between sessions and folders: surviving
rows and groups must keep their positions, with no polling-driven animation or
scrollbar movement. Stop and resume a child in an expanded two-session folder:
the header and expansion must remain while one child is still Working. Check
that actual completions remove rows, disclosure clicks still work, new sessions
append, and existing power/agent-visibility rules still apply. Run the signed
artifact and download-channel gates for the final release.

## v0.8.0 release scope

v0.8.0 adds Pi 0.87.1+ support and filters finished/idle Claude background
tasks on Stop. Record version 0.8.0, build 31, the full commit, and artifact
hashes with the results. Check Pi connection, task completion, and disconnect,
plus Claude background-agent completion. Power, daemon, and updater
implementations are unchanged. Verify the final signed/notarized artifact
and packaging before publication.

## v0.7.3 release scope

v0.7.3 changes only the update action's menu-row affordances and confirmation
ownership. Record version 0.7.3, build 30, the full commit, and artifact hashes
with the results. The completed v0.7.2 release evidence remains valid for
unchanged power, daemon, agent-hook, Settings, packaging, and recovery behavior.
Run the signed v0.7.2 -> v0.7.3 one-click update path from the menu popover and
confirm that it presents exactly one installer without opening Settings.

## v0.7.2 release scope

v0.7.2 changes only the menu popover's compact safety-state copy and leading
brand mark. Record version 0.7.2, build 29, the full commit, and artifact hashes
with the results. The completed v0.7.1 release evidence remains valid for
unchanged power, daemon, agent-hook, Settings, packaging, and recovery behavior.
Run the visual menu checks and the signed v0.7.1 → v0.7.2 one-click update path;
the latter is the live gate for the guided-DMG compatibility fix shipped in
v0.7.1.

## v0.7.1 release scope

v0.7.1 carries the v0.7.0 power, display, menu, Settings, passive-update,
recovery, and guided-installer changes, and corrects the mounted-DMG payload
check. Record version 0.7.1, build 28, the full commit, and artifact hashes with
the results. The completed v0.7.0 UAT remains evidence for unchanged behavior;
repeat the fresh-install and one-click-update paths with the signed v0.7.1
candidate because packaging and update validation are the affected release
boundaries.

## Manual replacement bridge

Run this once from a signed v0.6.5 install to the signed v0.7.1 candidate. It
proves the path required for existing users; do not substitute a fresh install.

1. With v0.6.5 installed at `/Applications/Let It Brew.app`, record its version
   and build, relevant preferences, agent connection states, a harmless session
   data fixture, daemon registration and health, and the exact `SleepDisabled`
   value.
2. Quit Let It Brew. Do not uninstall it or disconnect its agents.
3. Verify the v0.7.1 DMG against the candidate's generated checksum and release
   manifest. Open it, drag **Let It Brew.app** to **Applications**, and choose **Replace**.
4. Relaunch from Applications and confirm version 0.7.1, build 28.
5. Confirm the recorded preferences, agent connections, and session fixture are
   unchanged. Confirm the daemon's registered/absent state and health match the
   pre-replacement state with the v0.7.1 identity.
6. Confirm `pmset -g` has the exact recorded `SleepDisabled` value and there is
   no unexpected sleep debt, updater workspace, staged app, or backup.

This bridge bypasses the updater inside v0.6.5; it does not exercise the
corrected mounted-DMG validator. That validator requires a separate one-click
update from signed v0.7.1 to a signed version newer than v0.7.1 whose DMG uses
the guided layout. Run the checklist below when that authorized candidate
exists.

## One-click update

Run update UAT only from a Developer ID signed, release-verified install at the
exact path `/Applications/Let It Brew.app`. Record the old and new marketing
versions, decimal builds, full artifact hashes, app/daemon/helper CDHashes, and
the exact `SleepDisabled` entry before changing anything.

First exercise **Settings → General → Check for Updates…** when the current
published release is equal to or older than the installed app. It must report
**Let It Brew is up to date.** without downloading or quitting.

An available-update check requires a strictly newer published GitHub release with
exactly these two versioned updater assets, plus the byte-identical website alias:

- `LetItBrew-<version>.dmg`
- `LetItBrew-<version>-SHA256SUMS`
- `LetItBrew.dmg` (direct website download; ignored by updater asset selection)

Publishing, uploading, tagging, or promoting a release always needs separate
authorization. Until an authorized higher release exists, the production
available-update network path remains an explicit untested gate; do not replace
it with a report from the pure coordinator tests.

When that release exists, walk this checklist independently for each service
state below:

1. Record the old signed app identity, exact `SleepDisabled` baseline, relevant
   preferences, and a harmless user-data fixture beneath Let It Brew's user data
   directory.
2. Choose **Check for Updates…**. Confirm the exact expected version is offered
   and that cancelling once leaves the app, daemon, baseline, settings, and data
   unchanged.
3. Check again and choose **Install Update**. Observe one download/verification
   phase, the old app quitting, and exactly one ordinary app relaunching.
4. Confirm the result sheet reports success and the installed app version/build,
   hashes, Team ID, and app/helper/daemon identities match the new artifact.
5. Confirm the original preference values and user-data fixture are unchanged.
6. Confirm `pmset -g` still has the exact recorded `SleepDisabled` value and
   `/Library/Application Support/LetItBrew/` has no unexpected sleep debt.
7. Confirm there is no updater lock, backup, staged app, failed-new app, or
   download workspace left after proven success.

A signed attended rollback test must also inject one deterministic post-swap
failure, then prove the prior app relaunches, its original registered/absent
daemon state is restored, the exact baseline and user data survive, the result
sheet reports failure, and every retained recovery path is recorded. The isolated
shell failure matrix is necessary evidence but is not a substitute for this live
gate. Do not manufacture an unsafe power or service failure merely to satisfy the
checklist.

## Codex hook approval refresh

Run this flow with a signed candidate whose exact Codex hook definitions are
installed but not yet trusted:

1. Open **Settings → Agents** and confirm Codex reports **Action needed**.
2. In Codex, run `/hooks`, inspect the exact Let It Brew hook definitions, and
   approve them.
3. Return to Let It Brew without clicking **Refresh Connections**.
4. Confirm the Codex row changes to **Connected** automatically.
5. If Let It Brew says existing Codex sessions must be restarted, confirm an
   already-open session does not count as refreshed until it is restarted.
6. Repeat once by opening **Settings → Agents** directly and confirm pane
   appearance also refreshes the status without **Refresh Connections**.

Keep **Refresh Connections** available as the attended fallback. Confirm
returning to the app does not reconnect a Codex integration that the user
explicitly disconnected, does not recheck Claude as a side effect, and does not
create a timer or repeated refresh while the app remains active.

## Four-agent hook lifecycle matrix — not run by automation

This is an attended release gate, not evidence collected by this repository.
Do **not** run it against an unbacked-up local configuration, and do not record
which vendors happen to be installed today. At execution time, record the exact
installed vendor version. If a vendor is absent, mark that vendor's live UAT as
not run and keep it as a release gate; do not replace it with process-detection
or simulated evidence.

### Exact-target preservation and recovery (required for every vendor)

Before each vendor pass, resolve the selected user configuration target without
replacing its lexical symlink and make a private `0700` evidence directory
beneath `/private/tmp`. For each present final regular file, reserve a unique
recovery **name in that file's same parent directory and filesystem**. Do the
identical procedure for the exact registry
`~/Library/Application Support/LetItBrew/agent-hook-targets.json`.

For every present target and registry, record bytes and SHA-256, device/inode,
mode, owner/group, flags, mtime and birthtime where available, ACLs, and extended
attributes. `ctime` and link count are audit observations only: a same-directory
rename can legitimately change them, so do not require impossible equality.
Retain the original inode by atomically moving the original final file to a
unique same-directory recovery name, then create a disposable test copy at the
lexical target. Keep any lexical symlink unchanged. This lets the watched-agent
switch operate only on the disposable copy while the original inode remains
recoverable.

On normal cleanup, quit the Dev candidate, atomically move any test target to a
unique same-directory quarantine name, then atomically rename the retained
original recovery inode back to its lexical final target. Verify the recorded
bytes, digest, device/inode, mode, ownership, flags, mtime/birthtime where
available, ACLs, and xattrs. Apply this verification to the registry too. If a
test or Mac crashes, do not reconnect or overwrite anything: with the candidate
quit, perform that same quarantine-then-rename recovery before resuming normal
use. Keep the quarantine file for diagnosis until the verification succeeds.

For a truly absent target or registry, record absence rather than creating a
placeholder or recovery inode. After the pass, quarantine any created test file
and verify absence again. Do not promise inode identity for a file that did not
exist before the pass.

Turn the agent's watched switch on, verify its healthy state, and record whether
an existing session needs restart. For every pass use harmless work and verify:

1. `SessionStart` is Idle; a prompt makes it Working; a stop makes it Idle; and
   session end removes the record.
2. The Working → Idle → Working sequence updates the row and open-lid hold
   within two polls; removal releases it when it is the final Working record.
3. Turning the watched switch off immediately hides that vendor's records and
   removes only the owned configuration. Restore every backed-up target's exact
   bytes and metadata after the pass, or remove a target only when true absence
   was recorded before the pass.

Run these vendor-specific additions rather than claiming untested parity:

### Claude Code

Verify untrusted-workspace holdback before workspace trust. Run `/compact` at
an idle prompt and confirm the session stays Idle; run it in a fresh session
with too few messages to compact and confirm it stays Idle. Let a turn
auto-compact and confirm it stays Working until its `Stop`. Interrupt a turn
with Esc, confirm it stays Working, then run `/compact` and confirm it becomes
Idle. Start two child `agent_id` values, stop one child only, and confirm the other
remains Working. Confirm `StopFailure` becomes Idle and `Stop` remains Working
while `background_tasks` is nonempty, then becomes Idle after a later empty
Stop. Where the documented permission lifecycle is observed, it preserves the
existing Working state.

After a parent stops with an active background child, let the final child finish.
When its `SubagentStop` reports no remaining background work, confirm the parent
becomes Idle without another user prompt or parent Stop. Repeat with another
background task still running and confirm the hold remains. End a parent session
with children and confirm none of that session's rows remain; a second Claude
session must remain unaffected. Resume the ended session and confirm new work
appears normally.

Record interruption separately: Claude does not promise a Stop hook for a user
interrupt. A stopped parent with a still-running monitor, or a turn interrupted
without a later terminal event, can remain Working under the hook-only contract.
Do not claim these cases fixed solely from the parent/child cleanup regression.

### Codex

Verify `/hooks` trust approval before lifecycle observation, including the
`Interrupt` hook after upgrading an existing install. Press Esc during a turn
and confirm it becomes Idle. Run `/compact` at an idle prompt and confirm the
session stays Idle. Exercise two simultaneous distinct `agent_id` values; each
remains Working until its own `SubagentStop`. End a session with children and
confirm none of its rows remain. Where the documented permission lifecycle is
observed, it preserves the existing Working state.

Codex cannot be made to omit `SubagentStop` on demand, so replay that case
through the installed helper with a throwaway session. Pipe each payload, such
as `{"session_id":"uat-silent","cwd":"/tmp","agent_id":"A"}` (omit `agent_id`
for parent events), to `/Applications/Let It Brew.app/Contents/Helpers/letitbrew
hook codex <Event>`. Send `UserPromptSubmit`, `SubagentStart` for `A`, `Stop`,
`UserPromptSubmit`, `SubagentStart` for `B`, then `Stop`. Confirm `A` disappears
at the second `Stop` while `B`, heard during that turn, stays Working and holds
the Mac. Repeat with a new session ID and `Interrupt` in place of the final
`Stop`. End both sessions with `SessionEnd` and confirm none of their rows
remain.

### OpenCode

Test only a stable 1.x local CLI/app runtime. Confirm permission requests and
questions become Idle, while permission replies, answered questions, and
rejected questions return to Working. Send duplicate `session.status: idle`
and `session.idle` edges and confirm both remain idempotent.

### GitHub Copilot CLI

Confirm selected hooks remain silent and exit zero. Exercise permission prompts
and question tools and confirm they become Idle; a later `PostToolUse` for the
completed question returns to Working. Exercise `ErrorOccurred` with the tested
CLI version: `recoverable: true` must preserve the prior state, while
`recoverable: false` must become Idle.

At the end of each pass, complete the exact-target recovery and verification
above for the registry and every selected configuration target. This matrix never
permits live process detection, CPU detection, or transcript parsing as a
substitute for a lifecycle hook.

## Concurrent Working sessions and adaptive menu

Run this only with an isolated, signed Dev candidate. Do not install, launch, or
exercise the production bundle for this check. Keep closed-lid support disabled,
do not approve or register the Dev background service, and confirm
`com.ruban24.letitbrew.dev.daemon` is absent before, during, and after the run.
This is an open-lid assertion and menu test; it must not change `SleepDisabled`.

Before connecting any agent, follow **Exact-target preservation and recovery**
above for every selected target and registry. Do not use `ditto` or another
copy as restoration evidence: the retained same-directory original inode is the
only restore authority. Record true absence separately; do not create a
placeholder backup for an absent config.

Then record:

- the candidate commit and SHA-256 of the candidate app executable;
- the Dev bundle ID and the app's signing identity;
- whether each Claude, Codex, OpenCode, and Copilot user target exists;
  every resolved target path; a byte-for-byte backup of every existing file; and
  each file's pre-test SHA-256; and
- affirmative absence of the Dev daemon registration and process.

Use one newly created disposable root beneath `/private/tmp`, with two
same-named project folders at different full paths. Start sessions from the
connected agents for use in those folders; begin the matrix with all sessions in
the first full path. Use only harmless test work. Do
not inspect, copy, screenshot, or include notification prose, prompts, responses,
reasoning, tool details, or final assistant text in the evidence; record only
structural events, counts, hold state, and menu/accessibility observations. Each
expected transition must appear within two one-second polls. For every numbered
step below, record the actual visible Working count and whether the Dev app's
open-lid `PreventUserIdleSystemSleep` assertion is present or absent.

1. Make one session Working. Expect one flat row and the open-lid assertion.
2. Make a second session in that same full folder path Working. Expand its
   disclosure header and expect two aligned children and the assertion still
   present.
3. Make three more sessions Working in that folder, for five total. Expect one
   header and four session rows in the 294-point visible window, with the fifth
   child reachable through the single outer scroll.
4. Trigger a harmless permission request in a Working session without recording
   its prose. A `PermissionRequest` or permission-prompt notification must leave
   the visible count, row state, and assertion unchanged.
5. Make one session Idle through `Stop` or an idle notification. Its child row
   must disappear, the visible count must fall by one, and the assertion must
   remain present. Submit new work in that same session; it must reappear as
   Working and restore the previous visible count.
6. Make two sessions in the second same-named folder Working, allowing other
   sessions to become Idle as needed to keep the total near five. Confirm the
   full paths remain distinct groups. Expand the second group and confirm the
   first collapses; manual expansion must not jump while the chosen group remains
   eligible.
7. Make every session Idle. All rows must disappear and the open-lid assertion
   must be absent.

Record these visual and accessibility results during the matrix:

- popover viewport: test once at the current display scaling and once after
  selecting **System Settings > Displays > Larger Text** for the display that
  contains the menu bar. Before changing the display, record its exact current
  resolution/scaling selection. At both scales require a 344-point width, one
  outer vertical scroll, no nested group scroll, and a visible cap of 294 points
  (one 54-point header plus four 60-point rows). After the scaled pass, restore
  the exact recorded display selection and verify the restoration;
- accordion: at most one repository expanded, with disclosure state announced;
- alignment: grouped children have the same logo, text, and timer columns as a
  flat row, with no indentation; visible rows show the agent and project folder,
  while colliding eight-character ID prefixes lengthen until each accessibility
  label's short ID is unique; and
- VoiceOver: group labels include the full folder path, session count, agent
  summary, and expanded/collapsed state; child labels include agent, full folder
  path, short ID, Working state, and accumulated active time; disclosure and
  session-action controls remain keyboard reachable.

At cleanup, quit the Dev app and end the test sessions before removing only the
exact disposable root. Unless the user explicitly approves retaining the
validated Let It Brew-owned hooks, use the quarantine-then-atomic-rename
procedure above to restore each retained original target and registry inode
without replacing a lexical symlink. Quarantine a newly created config only when
preflight recorded true absence. Finally record the visible Working count as
zero, the open-lid assertion as absent, and the Dev daemon registration and
process as absent throughout.

## Uninstall

Uninstall's filesystem effects have their own throwaway-home check:

```sh
scripts/test-uninstall-safety.sh
```

The daemon gates and the app's self-trash cannot be automated — they need a
reinstall per run. Verify them attended on a signed install at
`/Applications/Let It Brew.app`:

1. Record whether Let It Brew is active or already paused. Choose **Uninstall
   Let It Brew…** and confirm that exactly one confirmation appears.
2. Cancel once. A previously active app must resume; a previously paused app
   must stay paused. Start uninstall again, confirm, and verify the dialog stays
   dismissed throughout teardown.
3. `sudo launchctl print system/com.ruban24.letitbrew.daemon` reports no such
   service.
4. `pgrep -f Let It Brew` reports nothing.
5. `pmset -g | grep SleepDisabled` matches the value recorded before the test.
6. `/Library/Application Support/LetItBrew/` contains no `.sleep-debt.json`.
7. `~/Library/Application Support/LetItBrew/` is absent.
8. `defaults read com.ruban24.letitbrew` reports the domain does not exist.
9. `Let It Brew.app` is in the Trash and absent from `/Applications`.

For a never-registered Launch at Login state, confirm uninstall treats both
Service Management's documented `kSMErrorJobNotFound` and macOS 26's observed
`SMAppServiceErrorDomain (1)` response as already absent only when Let It Brew
did not record an enabled choice. The app must quit without showing a leftovers
report.

If a genuine best-effort step is forced to fail, confirm the report says the
app bundle was removed only when that is true, confirms the privileged
background service is stopped, gives exact cleanup steps, hides the ordinary
menu-bar item, and labels its final action **Finish & Quit**.
A Launch at Login failure must also offer **Open Login Items…**, and its copied
diagnostic must include the NSError domain, code, and nested underlying error
when one exists.

Close the Settings window immediately after confirming uninstall, before
teardown completes. If a best-effort failure reaches the report, confirm the
menu-bar popover shows only **Uninstall needs attention** and **Show Cleanup
Instructions**, not the ordinary paused interface. Opening those instructions
must reopen Settings and present the report from any selected pane; once the
report is visible, the ordinary menu-bar item must disappear.

If a real hard gate blocks during an attended run, do not manufacture a second
failure. Confirm the error remains visible while the app stays paused and that
**Try Again** and **Resume Let It Brew** remain usable. When the diagnostic is
offered after a retry or a confirm-time refusal, confirm **Copy Diagnostic**
also remains usable.

`UninstallEnvironmentLive.swift` and the model actions that drive the real
uninstall have no automated coverage. The checklist above is the only evidence
for the live teardown.

## The three service states

The update and uninstall checklists must be walked independently for each state
below. Reconciliation never gates on the "Keep agents working when the lid is
closed" toggle: it proves whether the daemon is present or affirmatively absent.
Uninstall unregisters a present daemon and skips unregister only after fresh
affirmative absence, so all three states must genuinely complete rather than
skip themselves based on the preference.

**1. Never registered.** A fresh copy where the closed-lid toggle has never been
turned on. There is no service to reconcile or unregister. For uninstall, a
fresh affirmative absence result skips the Service Management unregister call
and cleanup completes normally. For update UAT: the daemon is affirmatively
absent before and after, and no launchd job or daemon process appears.

**2. Registered and running.** Turn the toggle on, click **Set Up Closed-Lid
Support** if shown, and approve Let It Brew in **System Settings → General →
Login Items & Extensions → App Background Activity**. Confirm
`sudo launchctl print system/com.ruban24.letitbrew.daemon` reports
`state = running`, then run the checklist. This is the primary case. For update
UAT: afterwards exactly one new daemon answers with the installed candidate's
native CDHash/version/build.

**3. Stranded — registered, but the toggle is off.** Repeat state 2 to get the
daemon approved and running, then turn the closed-lid toggle back **off** before
uninstalling or updating. Turning the toggle off releases the sleep hold but does
not unregister the daemon, so the service is still registered even though the
preference now reads "off". Confirm `launchctl print` still reports the daemon
registered before you start. Uninstall must still reconcile and unregister it
exactly as in state 2; update must follow the registered path and emerge as the
strictly identified new daemon. **The false preference must never be treated as
daemon absence** — this is the regression that caused the most trouble in this
work.
