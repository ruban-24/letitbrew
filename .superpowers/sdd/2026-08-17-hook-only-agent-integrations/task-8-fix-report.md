# Task 8 review and FD fix report

## Red to green evidence

The final rereview’s red cases were converted into deterministic executable
coverage: quarantine mismatch restores or preserves recovery safely;
publication validates its active name; strict registry extras fail; app
recorded-A inspection and healthy migration launch the exact helper request;
and command-level fault seams prove real persistence/removal ordering only
inside an anchored test home.

```text
swift test                                                       PASS (629 tests)
swift test --filter 'ExactFileSnapshotTests|ExactFileTargetTests|AgentInstallRegistryTests'
                                                                 PASS (58 tests)
swift build                                                      PASS
agent contract, repo root and /private/tmp                       PASS
uninstall contract, repo root and /private/tmp                   PASS
xcodegen generate + unsigned Debug LetItBrew build              PASS
git diff --check                                                 PASS
```

## Closed final-rereview findings

1. Descriptor publication/removal restores a still-owned quarantine to an
   absent active name and never overwrites an active replacement.
2. The registry decoder requires exactly `version` and `targets` before typed
   decoding.
3. The app coordinator uses one selected recorded-or-configured target for
   inspection, helper stdin, and post-check across all five agents.
4. FD capture/publication has post-read evidence, bounded collisions,
   identity checks, publish proof, durability sync, and deterministic races.
5. Snapshot, production-closure, A/B, doctor, shell, OpenCode, and uninstall
   safety matrices are executable, including exact foreign structural and
   `SleepDisabled` preservation.
6. Final-fix review: app presentation consumes selected A/final health;
   test replacement is descriptor-relative; the source gate parses whole calls
   and rejects an adversarial multiline fixture; retry, EINTR/short-read, and
   absent-post-publish assertions are executable.

## Final slice files

- `Sources/letitbrew/InstallCommand.swift`: test-home-only command fault seams
  used to exercise registry/vendor/remove/clear order and active replacement.
- `scripts/test-agent-hook-contracts.sh`: all-five real CLI fault matrix,
  recorded-A/foreign-B lifecycle, malformed four-JSON refusal, source and
  power-baseline gates.
- `scripts/test-uninstall-safety.sh`: Cursor/Copilot structural preservation,
  clear/retry no-rewrite, and active replacement survival.

## Commit

Final matrix commit: `177a5e5 test: complete hook transaction safety contracts`.
The complete chain from `8e22b5b` is recorded in `task-8-report.md`.

## Attended UAT only

No automated or source gap remains in Task 8. Still attended: a signed/
notarized app pass against real Claude, Codex, Cursor, OpenCode, and Copilot
installations. No live vendor configuration was touched.

The last-fix AppCore boundary and independent source-gate fixtures are covered
by the current focused test/build and shell evidence.

DONE
