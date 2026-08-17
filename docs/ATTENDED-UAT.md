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

## One-click update

Run update UAT only from a Developer ID signed, release-verified install at the
exact path `/Applications/Let It Brew.app`. Record the old and new marketing
versions, decimal builds, full artifact hashes, app/daemon/helper CDHashes, and
the exact `SleepDisabled` entry before changing anything.

First exercise **Settings → About → Check for Updates…** when the current
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
3. Return to Let It Brew without clicking **Check Again**.
4. Confirm the Codex row changes to **Connected** automatically.
5. If Let It Brew says existing Codex sessions must be restarted, confirm an
   already-open session does not count as refreshed until it is restarted.
6. Repeat once by opening **Settings → Agents** directly and confirm pane
   appearance also refreshes the status without **Check Again**.

Keep **Check Again** available as the attended fallback. Confirm returning to
the app does not reconnect a Codex integration that the user explicitly
disconnected, does not recheck Claude as a side effect, and does not create a
timer or repeated refresh while the app remains active.

## Five-agent hook lifecycle matrix — not run by automation

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
lexical target. Keep any lexical symlink unchanged. This lets Connect and
Disconnect operate only on the disposable copy while the original inode remains
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

Choose explicit **Connect**, verify its healthy state, and record whether an
existing session needs restart. For every pass use harmless work and verify:

1. `SessionStart` is Idle; a prompt makes it Working; a stop makes it Idle; and
   session end removes the record.
2. The Working → Idle → Working sequence updates the row and open-lid hold
   within two polls; removal releases it when it is the final Working record.
3. **Disconnect** immediately hides that vendor's records and removes only the
   owned configuration. Restore every backed-up target's exact bytes and
   metadata after the pass, or remove a target only when true absence was
   recorded before the pass.

Run these vendor-specific additions rather than claiming untested parity:

### Claude Code

Verify untrusted-workspace holdback before workspace trust. Exercise
`PreCompact`, `PostCompact`, and `SessionStart(source: compact)` as Working.
Start two child `agent_id` values, stop one child only, and confirm the other
remains Working. Confirm `StopFailure` becomes Idle and `Stop` remains Working
while `background_tasks` is nonempty, then becomes Idle after a later empty
Stop. Where the documented permission lifecycle is observed, it preserves the
existing Working state.

### Codex

Verify `/hooks` trust approval before lifecycle observation. Exercise compact
lifecycle events and two simultaneous distinct `agent_id` values; each remains
Working until its own `SubagentStop`. Where the documented permission lifecycle
is observed, it preserves the existing Working state.

### Cursor desktop Agent and Cursor CLI

Record installed versions separately and exercise all six ordinary mapped events
on each surface. Exercise `subagentStart`/`subagentStop`, including an async
child that survives parent `stop`. Permission-wait UAT is **N/A — no documented
supported hook**. Do not claim parity for a surface or version that was not
exercised.

### OpenCode

Test only a stable 1.x local CLI/app runtime. Record whether
`permission.updated`/`permission.replied` (v1.18.3) and/or the current
`permission.asked` were observed; these permission observations are ignored for
the two-state decision. Send duplicate `session.status: idle` and `session.idle`
edges and confirm both remain idempotent.

### GitHub Copilot CLI

Confirm selected hooks remain silent and exit zero. Record the `ErrorOccurred`
limitation without installing a decision-capable hook. Permission-wait UAT is
**N/A — no documented supported hook** for v0.6 unless a later documented
version changes it.

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
- whether each Claude, Codex, Cursor, OpenCode, and Copilot user target exists;
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
  flat row, with no indentation, and colliding eight-character ID prefixes
  lengthen until each visible short ID is unique; and
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
