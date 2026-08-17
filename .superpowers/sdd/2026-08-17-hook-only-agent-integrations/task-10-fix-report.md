## Task 10 review fixes

## Rereview follow-up

## Second rereview follow-up

- Immutable exact preparation state now controls launch restart evidence:
  healthy-owned registry backfill reports no vendor-byte change; absent and
  repairable preparation successes report a change.
- Launch inspection carries the exact selected target into the Codex trust
  check. Trusted, approval-required, and unverifiable results map through the
  standard connection policy without ambient-path fallback.
- The exact-A refusal proof now creates real A/B files, swaps an A parent
  component after capture, records the sole A preparation, and verifies B's
  bytes and mtime are unchanged.

- `AgentLaunchOutcomeCoordinator` executes only immutable launch
  preparations and presents all five rows from original inspection plus helper
  outcome. It has no target/environment resolver; the exact-A refusal test
  records the sole A launch and preserves an ambient-B sentinel.
- `AgentLiveDiskReader` tests now cover registry, recorded JSON, configured
  JSON, OpenCode, and dangling symlink policies.
- `AgentConnectionMigration.persist` makes write-V2 then remove-legacy an
  injected, executable ordering boundary for missing, empty, populated,
  malformed, and unknown values.
- `AgentSessionVisibilityPipeline` is the model's shared selection and
  suppression composition; its test proves suppression is retained across a
  disconnect/reconnect selection transition.
- `AgentUninstallHooksCoordinator` proves positive intent is emptied and
  visibility refreshed before one all-five removal batch.  The action
  coordinator test retains an unresolved helper completion and proves it
  cannot roll intent back.

### Closed review findings

1. Launch no longer invokes the ordinary refresh/repair path after exact
   preparations: only stored `decision.preparations` run at launch.
2. Every unselected catalog row is immediately presented as intentionally
   disconnected with a Connect action.
3. Supplied-set reapplication now shares the normal positive visibility and
   `SessionTrackingPolicy` suppression pipeline.
4. Added `AgentLiveDiskReader`: registry and recorded targets use
   `ExactFileCapture`, configured JSON targets alone resolve once, and
   OpenCode remains no-follow.  Inspection validates adapter install
   transforms before reports.
5. Added injected `AgentConnectionMigration`; malformed V2 is authoritative
   empty selection, only a missing key reads legacy state, and V2 is written
   before legacy cleanup.
6. `uninstallHooks()` synchronously persists empty selection/reapplies
   visibility before all five removals; failure names derive from `AgentID`.
7. Strengthened method-scoped model source checks and added repairable,
   malformed, migration, and live-reader test coverage.

### Evidence

- Focused rereview behavior suite: PASS, 12 selected/parameterized tests.
- `swift test --filter AgentLiveDiskReaderTests`: PASS.
- Full `swift test`: PASS, 662 tests.
- `swift build`: PASS.
- `xcodegen generate`: PASS.
- Unsigned Debug `xcodebuild`: `** BUILD SUCCEEDED **`.

`git diff --check` passes. The only attended follow-up is real-vendor app UAT.

## Second rereview completion

- `AgentLiveDiskReader` now accepts injected registry and exact-target readers
  while retaining its descriptor-capture production defaults.  Tests prove one
  selected read for both recorded and configured provenance, no ambient
  fallback, and refusal of real nonregular/unreadable, registry, recorded,
  OpenCode, and dangling-symlink paths.
- Launch still has no resolver after inspection: its exact preparation outcome
  remains the sole mutation authority.  Healthy exact preparation is
  registry-only/no-restart; absent and repairable exact preparations request a
  restart only after a successful vendor mutation.  Codex trust uses the
  immutable selected target.
- `AgentUninstallHooksCoordinator.complete` is now the model's live async
  completion authority for complete uninstall.  It keeps selection empty,
  gives every agent an exact terminal row, returns only failed IDs for retry,
  and derives fallback diagnostics from the real display name.  A later helper
  result updates diagnostics only; it has no persistence/reconnect path.

### Final evidence

- Task 10 required focused policy/uninstall filters: PASS.
- Rereview focused AppCore suite: PASS, 20 selected/parameterized tests.
- Full `swift test --skip-build`: PASS, 668 tests.
- `swift build`: PASS.
- `xcodegen generate`: PASS.
- Unsigned Debug `xcodebuild`: `** BUILD SUCCEEDED **`.
- `git diff --check`: PASS.

## Third rereview completion

- `AgentLaunchTrustCoordinator` is the model-bound selected-only Codex trust
  boundary. Empty and Claude-only selections perform no Codex probe; selected
  Codex receives only the original inspected target. A selected Codex row with
  missing trust evidence is fail-closed/actionable.
- The A/B race proof now captures an anchored existing A through Task 8's
  `CapturedExactFile`, swaps its parent to a foreign B inode, and invokes the
  real descriptor `AtomicFile.write` boundary. The write refuses and B's
  bytes, mode, device/inode, and mtime remain identical.
- The live reader has deterministic after-registry and before-target-capture
  seams around its production exact capture. Recorded/configured component and
  registry replacement tests prove one selected route, invalid/no fallback,
  and no ambient B read.
- Connection helper completions now carry terminal presentation plus the
  unchanged selected set and are consumed by the model's live disconnect task.
  Complete uninstall retains its async helper completion, stores only failed
  retry IDs, and runs a subsequent retry only for those IDs after synchronous
  empty-selection visibility refresh.

### Third rereview evidence

- Expanded focused Task 10 suite: PASS, 21 selected/parameterized tests.
- Full `swift test`: PASS, 673 tests.
- `swift build`: PASS.
- `xcodegen generate` and unsigned Debug `xcodebuild`: PASS.
- `git diff --check`: PASS.

DONE
