## Task 10 — explicit five-agent connections

### RED

`swift test --filter AgentConnectionModelContractTests` failed before the
model migration: the source contract could not find `connectedAgentIDsV2`,
catalog-derived rows, the action coordinator, disk inspection, launch runner,
or the positive snapshot refresh bindings.

### GREEN

- Added `AgentDiskInspection`, which selects a recorded registry target before
  the single legacy/default target and classifies the five pure adapters
  without process launch or writes.
- Added `AgentConnectionActionCoordinator` and
  `AgentLaunchPreparationRunner`; the latter forwards the original exact
  snapshot and expected state to `ExactTargetPreparation` unchanged.
- Migrated the app model to `connectedAgentIDsV2`, catalog-derived rows,
  positive visibility, synchronous persist/refresh before Connect or
  Disconnect helper work, selected-only Codex refresh, and a one-time legacy
  migration which removes the old key only after persisting V2.
- Removed Task 9's temporary negative-intent helper shims and visibility
  overload after all live model callers moved to positive selection.
- Expanded app uninstall to independent Cursor, OpenCode, and Copilot steps;
  all five helper removals continue after failures and are retained in the
  existing leftover report.

### Evidence

- `swift test --filter AgentConnectionModelContractTests` — PASS (1).
- Focused Task 10 combined filters — PASS (36 before the final additional
  helper/uninstall table cases; final focused rerun PASS, 32 selected cases).
- `swift test` — PASS, 649 tests.
- `swift build` — PASS.
- `xcodegen generate` — PASS.
- `xcodebuild -project LetItBrew.xcodeproj -scheme LetItBrew -configuration Debug -derivedDataPath /private/tmp/letitbrew-agent-hooks-model-derived CODE_SIGNING_ALLOWED=NO build` — `** BUILD SUCCEEDED **`.
- `git diff --check` — PASS.

### Scope pressure

`UninstallCoordinator.swift`, `AgentSessionVisibilityPolicy.swift`, and their
tests changed mechanically because the shipping app protocol had only the
old two removal steps and a temporary Task 9 negative visibility overload.
They are required to compile and to make the Task 10 five-agent migration
complete; no menu UI was changed.

### Commit

Pending `feat: orchestrate explicit five-agent connections`.

DONE
