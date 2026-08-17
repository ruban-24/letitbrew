# Task 11 documentation fix report

Base: `967d0d1`; first documentation correction: `e2e7ab9`

## RED evidence

Added `publicReadmeDocumentsTheOptionalFiveAgentCatalog` before changing the
README, then ran:

```text
swift test --filter ProductTerminologyContractTests
```

The new test failed as intended: `OpenCode` and `GitHub Copilot CLI` were
absent, and the README still contained the obsolete automatic Claude/Codex,
two-agent-only, and Cursor-unsupported claims.

## GREEN evidence

Updated the README to document the exact five-name catalog in product,
comparison, first-launch, session-row, supported-agent, Settings, connection,
local-data, uninstall, troubleshooting, scope, support, and trademark copy.
It now describes explicit optional Connect behavior and the narrowly scoped
pre-v0.6 owned Claude Code/Codex migration. The local-data table is derived
from the adapters:

- `~/.claude/settings.json`
- default `~/.codex/hooks.json`; when `CODEX_HOME` is present,
  `<CODEX_HOME>/hooks.json`
- `~/.cursor/hooks.json`
- default `~/.config/opencode/plugins/letitbrew.js`; when
  `OPENCODE_CONFIG_DIR` is present,
  `<OPENCODE_CONFIG_DIR>/plugins/letitbrew.js`
- default `~/.copilot/hooks/letitbrew.json`; when `COPILOT_HOME` is present,
  `<COPILOT_HOME>/hooks/letitbrew.json`

The terminology contract reads `README.md`, requires every `AgentID`
display name, rejects the three obsolete claims, and pins the existing MIT
badge unchanged.

## Rereview correction

The original README test was intentionally expanded after rereview showed that
the five display names could be satisfied by the trademark footer alone and
that shell-style `${VAR:-default}` shorthand incorrectly described empty
environment values. The strengthened test first failed against that shorthand
and the unguarded operational facts.

The final test extracts `## Supported agents`, `## Privacy and local data`,
and `## Uninstalling` before asserting the relevant facts. It now proves:

- all five exact display names appear in `## Supported agents`, not merely the
  footer;
- a fresh install is optional, requires Connect, mutates nothing before that
  choice, and limits pre-v0.6 migration to previously owned Claude Code and
  Codex connections;
- the default and present-variable paths match `CODEX_HOME`,
  `OPENCODE_CONFIG_DIR`, and `COPILOT_HOME` adapter semantics without claiming
  an empty variable selects a default;
- uninstall names all five agents, the Scope FAQ positively supports Cursor,
  OpenCode, and GitHub Copilot CLI, and the MIT badge remains unchanged.

Commands and results:

```text
swift test --filter ProductTerminologyContractTests  # PASS: 4 tests
swift test --filter MenuPresentationPolicyTests      # PASS: 19 tests
swift test --filter AgentConnectionPolicyTests       # PASS: 5 tests
swift test                                            # PASS: 677 tests
swift build                                           # PASS
git diff --check                                      # PASS
```

No Xcode build was rerun because this fix changes only `README.md` and a
SwiftPM terminology-contract test; it does not change SwiftUI or app code.

## File scope and self-review

Changed only:

- `README.md`
- `Tests/LetItBrewAppCoreTests/ProductTerminologyContractTests.swift`
- this report

The MIT badge remains the existing `License: MIT` badge. No Task 13 licensing
or trademark-policy work, product behavior, assets, downloads, or UI changes
were included.

Known attended-UAT gap: documentation wording and path derivation are covered
by source-backed tests and adapter inspection; no live third-party agent
configuration was connected or changed.

DONE
