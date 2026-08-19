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

## Setup notes

- Requires macOS 14 or later. The app includes Apple silicon and Intel code.
- Install and run the app only as `/Applications/Let It Brew.app`.
- Allow Let It Brew under **System Settings → General → Login Items & Extensions
  → App Background Activity** if you want closed-lid support.
- Codex requires a one-time `/hooks` trust approval. Sessions that were already
  open when hooks changed may need to be restarted.

## Scope and known limitations

- Only local sessions are observed. Remote, cloud, and SSH sessions are out of
  scope.
- An Idle session is intentionally allowed to sleep and is hidden from the menu.
- Launch at Login is optional and off until you enable it.
- Update checks are user-initiated. They require access to GitHub Releases; there
  is no background polling and no update-channel choice.

## Release validation

Every release candidate must clear all of the following before it ships:

- The Swift test suite, updater and transaction script assertions,
  direct-distribution assertions, Debug and Release builds, and release-artifact
  verification, all passing for the final source.
- Functional testing across agent connection, work/input/resume/completion, pause
  persistence, disconnect/reconnect, concurrency, settings, and local surface
  presentation.
- Deterministic safety testing across exact `SleepDisabled` restoration, process
  death, stale debt, boot repair, service loss, lid/display edges, battery,
  thermal pressure, and unreadable state.
- Developer ID verification, Apple notarization, stapler validation, Gatekeeper,
  architecture, identifier, content, and checksum checks on the published DMG.
- Signed attended UAT exercising uninstall and update separately against an
  absent daemon, a registered/running daemon, and a stranded registered daemon
  whose closed-lid preference is off — see
  [docs/ATTENDED-UAT.md](docs/ATTENDED-UAT.md). Update UAT also requires relaunch,
  settings/data preservation, strict new-daemon identity, exact baseline
  preservation, and a proven post-swap rollback.

Physical lid/display topology cases may be recorded as approved N/A when the
required hardware configuration is unavailable; they are never represented as
physical passes.

## Privacy and support

Session records and preferences stay on the Mac. A manual update check contacts
GitHub only for release metadata and, after confirmation, the signed DMG and
checksum; no session or project data is uploaded. See [README.md](README.md) for
the exact local data locations, setup, troubleshooting, update, and uninstall
procedures.

When reporting a problem, include the Let It Brew version and build, macOS
version, Mac model, and reproduction steps. Do not include unrelated agent
configuration or private project contents. Report issues at
[GitHub Issues](https://github.com/ruban-24/letitbrew/issues).
