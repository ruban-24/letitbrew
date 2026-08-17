## Task 10 review fixes

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

- Focused Task 10 suite: PASS, 44 selected/parameterized tests.
- `swift test --filter AgentLiveDiskReaderTests`: PASS.
- Full `swift test`: PASS, 654 tests.
- `swift build`: PASS.
- `xcodegen generate`: PASS.
- Unsigned Debug `xcodebuild`: `** BUILD SUCCEEDED **`.

`git diff --check` passes. The only attended follow-up is real-vendor app UAT.

DONE
