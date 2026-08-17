# Task 12 report — hook-only five-agent qualification

## Scope

Modified the Task 12 pressure fixture and isolated harness, public support and
privacy documentation, attended UAT, manual uninstall guidance, bug selector,
and CI hook-contract gate. No live agent configuration was read, changed, or
installed; the pressure harness creates and removes only a validated
`/private/tmp/letitbrew-session-pressure.*` fixture.

## RED

After adding the exact 100-record all-five-agent assertion, the focused command
failed as intended: the old fixture produced only `claude` and `codex`, while
the assertion required all five `AgentID` values.

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/letitbrew-task12-clang \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/letitbrew-task12-swiftpm \
swift test --scratch-path /private/tmp/letitbrew-task12-tests \
  --filter SessionPressureTests
```

The failure was the expected five-agent identity mismatch.

## GREEN

- `scripts/test-session-pressure.sh` — PASS: validated private fixture,
  1/10/15/50/100 counts, five-agent round robin, 10 pressure tests.
- `CLANG_MODULE_CACHE_PATH=/private/tmp/letitbrew-agent-hooks-clang SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/letitbrew-agent-hooks-swiftpm swift test --scratch-path /private/tmp/letitbrew-agent-hooks-tests --no-parallel` — PASS: 681 tests, zero failures.
- `git diff --check` — PASS.

The pressure coverage proves 100 records are 20 per agent, old Working events
cannot override newer Idle events, a disconnected fifth raw record cannot hold,
and Claude/Codex/Cursor child records remain independent of sibling and parent
stops.

## Source-hygiene baseline

`scripts/tests/public-source-tests.sh` was run and currently fails before
evaluating Task 12 changes because approved HEAD already tracks historical
`.superpowers/sdd/.../task-{8,9,10,11}-report.md` paths, while the guard rejects
every tracked `.superpowers/` path. This task preserves those out-of-scope
historical reports and adds no source-hygiene script change; resolving that
pre-existing contract contradiction requires explicit scope direction.

## Attended UAT

The five per-vendor matrices were documented but intentionally not run. The only
remaining evidence is attended signed-app/vendor UAT with backed-up local
configuration; no local installation state was recorded.

DONE
