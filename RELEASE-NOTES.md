# Release notes

Let It Brew is a menu-bar macOS app that keeps a Mac awake while selected local
agent hooks report Working, then releases its hold when no managed session is
Working.

v0.6.0 and later are open source under the [Apache License 2.0](LICENSE).
Releases are distributed as a
signed, notarized, and stapled DMG from
[GitHub Releases](https://github.com/ruban-24/letitbrew/releases). Verify the DMG
against the SHA-256 published with the release.

---

## 0.6.5 (build 26)

Fixed:

- The one-click updater now receives the property-list output it requires when
  mounting a downloaded DMG. The mount command combined `hdiutil`'s `-quiet`
  and `-plist` options, so the mount succeeded but produced no property-list
  data. The updater then stopped at `mountDiskImage` with `The data couldn’t be
  read because it isn’t in the correct format.`

Updating:

- The broken mount command runs inside v0.6.4 and earlier, so those versions
  cannot install v0.6.5 automatically. Download and install v0.6.5 once from
  GitHub Releases. Settings and agent connections are preserved; subsequent
  in-app updates use the corrected mount command.

## 0.6.4 (build 25)

Fixed:

- The About pane now shows its full description. Extra top spacing added in
  v0.6.2 left too little room in the fixed-height Settings window, so SwiftUI
  compressed the description to one line and added an ellipsis. Removing that
  spacer restores the existing multiline layout without changing the window
  size.

Tested:

- The macOS app target builds after the layout change. The existing Swift and
  release-script suites continue to pass.

## 0.6.3 (build 24)

Fixed:

- The one-click updater now creates its private `Updates` workspace directory
  idempotently. The base directory lives at
  `~/Library/Caches/com.ruban24.letitbrew/Updates` and persists across updates,
  but it was created in a way that fails when it already exists. As a result the
  second and every later in-app update stopped at the `createWorkspace` stage
  with `The file “Updates” couldn’t be saved in the folder
  “com.ruban24.letitbrew” because a file with the same name already exists.` The
  first update on a machine succeeded; every one after it failed. Present since
  v0.5.0.

Updating:

- The broken step runs inside v0.6.2 and earlier, so once their update cache
  exists those versions cannot install v0.6.3 automatically. Fix it once, either
  way:
  - Remove the stale directory, then update from within the app:
    `rm -rf ~/Library/Caches/com.ruban24.letitbrew/Updates`, or
  - Download and install v0.6.3 once from GitHub Releases — the v0.6.3 build
    tolerates the existing directory.
  Settings and agent connections are preserved, and future in-app updates then
  work. Note: the app's Uninstall does not remove this cache directory, so
  uninstalling and reinstalling the same version does not clear it.

Tested:

- Regression coverage pins the idempotency contract: the old non-idempotent
  creation reproduces the exact `NSFileWriteFileExistsError` above on the second
  attempt, while the corrected creation accepts an already-existing base at
  owner-only `0700`. The existing update-transaction and direct-distribution
  suites continue to pass.

## 0.6.2 (build 23)

Changed:

- Unified the accent color to a single brewed purple. The Settings safety rows
  and the menu popover's flask mark now use the shared `BrewPurple` asset in
  place of the previous mix of orange and blue.
- The menu-bar status icon fills more of the flask when awake (0.62 of the
  glyph, up from 0.5) so the awake state reads as clearly filled against the
  empty idle outline at 18pt monochrome, where fill level is the only state
  signal.
- Minor Settings spacing above the app icon.

## 0.6.1 (build 22)

Fixed:

- The one-click updater now supplies Gatekeeper's required primary-signature
  context when assessing a downloaded DMG. This prevents the valid, notarized
  update from being rejected with `source=Insufficient Context` before mounting.

Updating:

- The affected updater is already inside v0.5.1 and v0.6.0, so those versions
  cannot install v0.6.1 automatically on affected macOS versions. Download and
  install v0.6.1 once from GitHub Releases; settings and agent connections are
  preserved. Future updates can then use the corrected updater.

Tested:

- The failure was reproduced against the byte-exact public v0.6.0 DMG. The
  contextless assessment failed with status 3, while the corrected command
  accepted the same DMG as a notarized Developer ID artifact.
- Regression coverage pins the primary-signature assessment contract, alongside
  the existing update transaction and direct-distribution suites.

## 0.6.0 (build 21)

New:

- Four optional, owned lifecycle-hook integrations: Claude Code, Codex,
  OpenCode stable 1.x, and GitHub Copilot CLI.
- Agent connections are explicit: choose **Connect** in Settings to install an
  owned hook integration, and **Disconnect** to remove it.
- OpenCode and GitHub Copilot CLI have native connection, lifecycle, menu,
  settings, and uninstall support alongside Claude Code and Codex.

Changed:

- Process, rollout, transcript, and ambient session observation have been
  removed. Only selected hook integrations can create managed activity.
- Public agent state remains only **Working** or **Idle**. Permission and input
  waits do not introduce extra public states.
- Grouped menu rows show the project folder instead of an internal session-ID
  fragment. Settings shows shared disconnected and restart guidance once, and
  the complete OpenCode logo is rendered without cropping or distortion.
- Hook installation, repair, disconnect, and uninstall are bound to exact
  recorded targets and preserve foreign agent configuration.
- Upgrades from a pre-v0.6 release carry forward only previously owned Claude
  Code and Codex connections. New OpenCode and GitHub Copilot CLI connections
  remain opt-in.

Tested:

- Attended OpenCode and GitHub Copilot CLI lifecycle UAT covered connection,
  Working/Idle transitions, questions and permissions, stop, disconnect, and
  owned-hook removal.
- Automated coverage includes the four-agent lifecycle contracts, concurrent
  session pressure, exact-target race resistance, uninstall preservation, and
  guarded update/distribution transactions.

Licensing:

- v0.6.0 and later use Apache License 2.0. The code remains open source, while
  [TRADEMARKS.md](TRADEMARKS.md) describes the distinct Let It Brew name, icon,
  and branding boundary for forks and redistributed builds.
- Signed app bundles contain exactly `LICENSE`, `NOTICE`, and `TRADEMARKS.md`
  under `Contents/Resources/Legal`, matching the repository files.

## 0.5.1

Fixed:

- Closed-lid setup now recognizes macOS’s current Background Activity approval
  response instead of showing a generic “Operation not permitted” error.
- When approval is needed, Let It Brew opens the correct System Settings pane,
  shows the exact steps (including the possible administrator password or Touch
  ID prompt), and checks again automatically when you return to the app.

Tested:

- Regression coverage includes the current `SMAppServiceErrorDomain` approval
  response and the existing legacy Service Management error mappings.

## 0.5.0

Stable release.

New:

- Adaptive concurrent-session rows: one Working session is flat, while two or
  more Working sessions in the same full folder path form an expandable group
  with collision-safe short IDs.
- Structural Codex lifecycle fallbacks discover active compacted continuations
  and subagents and observe completion or cancellation without decoding or
  retaining private content.

Changed:

- The public session model is now only **Working** and **Idle**. Idle sessions
  disappear on the next poll, while permission events preserve the prior state.
- The activity viewport uses one bounded outer scroll, one stable expanded
  repository at a time, and aligned flat and grouped rows.
- Session storage now uses bounded per-session locking, collision-safe filenames,
  and ordered terminal tombstones without putting hook failures in the agent's
  critical path.

Tested:

- The automated concurrent-session load qualifies 100 simultaneous sessions,
  including independent records, aggregate hold release, corruption isolation,
  grouping, and presentation.
- Signed attended validation covered mixed Claude Code and Codex sessions and
  accessibility at the default display scale.
- Manual release validation with macOS **Displays > Larger Text** scaling
  remains required.

## 0.4.1

New:

- A new Violet Signal identity across the macOS app icon, website artwork, and
  README hero. The potion now uses violet, indigo, and lilac instead of the old
  amber treatment.
- Concurrent Claude Code and Codex sessions in the same repository are tracked
  independently and presented reliably.
- Codex hook trust refreshes automatically after approval while preserving the
  explicit **Check Again** fallback.

Fixed:

- Uninstall confirmation, pause restoration, daemon reconciliation, and
  never-registered service handling are now stricter and more consistent.
- Launch-at-login and uninstall failures retain actionable diagnostics without
  treating ambiguous service errors as proof that the daemon is absent.

## 0.4.0

**Renamed from Brewkeeper to Let It Brew.** The bundle identifier, daemon label,
and application-support directory all changed with it. Preferences and session
records migrate on first launch.

New:

- **Settings → About → Check for Updates…** One confirmation downloads and
  verifies the signed DMG and checksum, safely preserves the actual registered or
  absent background-service state, installs through the guarded transaction, and
  relaunches without removing settings or session records.
- **Settings → About → Uninstall Let It Brew…** Releases holds, reconciles and
  unregisters any real background service even when the closed-lid preference is
  off, disconnects agents, removes local data and preferences, and moves the app
  to the Trash.
- New app icon, and a menu-bar glyph rendered as a template image so it follows
  the system appearance correctly.
- Polished menu bar and settings presentation.

Fixed:

- A registered background service is no longer treated as absent just because the
  closed-lid preference reads off. That *stranded* state previously caused
  uninstall to skip teardown.
- An unreachable daemon connection is no longer taken as proof the daemon never
  existed.
- Uninstall reports a Trash move that did not actually happen instead of claiming
  success.

## 0.3.0

Released as **Brewkeeper**. First publicly documented release.

- Observes local Claude Code, Claude Desktop Code, Codex CLI, and Codex app
  sessions.
- Holds only while at least one observed session is working. Ordinary questions,
  completion, stop, lost-session, pause, battery, and thermal states release the
  hold.
- Keeps native approval prompts protected until their tool finishes.
- Persistent **Pause** and explicit **Resume** actions.
- Connects supported agents automatically while preserving unrelated Claude and
  Codex configuration. Unsafe configuration is left untouched.
- Disconnecting an agent immediately hides its sessions and prevents them from
  keeping the Mac awake, without deleting the underlying session records.
- Closed-lid work through a signed background service with exact `SleepDisabled`
  baseline restoration and crash/reboot recovery.
- Authenticates the background service by protocol, version, build, signing
  identity, and exact Code Directory hash. A stale service is replaced only after
  that same authenticated service proves it is reconciled and quiesces.
- Staged, verified, same-volume atomic upgrade with rollback after any post-swap
  failure.
- No account, cloud service, telemetry, or user notifications.

Earlier internal builds were developed under the name **Sandman**.

---

Current installation and product details are in [README.md](README.md). See
[SUPPORT.md](SUPPORT.md) for troubleshooting, [docs/PRIVACY.md](docs/PRIVACY.md)
for local data, and [docs/ATTENDED-UAT.md](docs/ATTENDED-UAT.md) for release
validation.
