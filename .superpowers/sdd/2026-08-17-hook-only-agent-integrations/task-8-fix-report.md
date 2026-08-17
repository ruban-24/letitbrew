# Task 8 review and FD fix report

## Red/green evidence

Red fixtures covered active-name replacements, quarantine and temporary-name
substitution, restored-mtime content changes, missing-parent `EEXIST` races,
root/component swaps, final symlinks, malformed/unowned preflight, and
registry-to-vendor transaction boundaries. Each now has deterministic green
coverage.

```text
ExactFileTargetTests                                             PASS (32 tests)
Task-8 focused adapter/transaction/target suite                 PASS (130 tests)
swift test                                                       PASS (611 tests)
swift build                                                      PASS
agent contract, root and /private/tmp                           PASS
uninstall contract, root and /private/tmp                       PASS
xcodegen generate + unsigned Debug LetItBrew build              PASS
git diff --check                                                 PASS
```

## Closed findings

1. Preflight bytes/metadata are bound to one capture and descriptor commit.
2. Registry is strict version-1 `targets` JSON.
3. Registry loads/saves are no-follow, exact, private `0600`, and baseline-bound.
4. Test-home root/descendants are retained descriptor anchors.
5. Recorded final symlink substitution is refused.
6. Desktop preparation uses exact snapshot handoff for all five agents.
7. Doctor emits all requested states and always evaluates the watchdog.
8. Stale JSON registry retry clears only the record without vendor rewrite.
9. Snapshot/preparation/registry/transaction/fault matrices are executable.
10. Shell/OpenCode/grammar/foreign-structure/SleepDisabled/uninstall contracts are executable.

The later FD audit is also closed: `DirectoryAnchor`, `ExactFileTarget`,
`CapturedExactFile`, `CommandFilesystem`, descriptor registry/install/remove/
doctor/prepare paths, final-link resolver, publication race hooks, route
revalidation, and the source transport gate are all present and tested.

## Commits

The full chain from `8e22b5b` is recorded in `task-8-report.md`; the final
descriptor migration commits are `7704659`, `a4dc538`, `cd7793f`, `9579c78`,
`e8a0cab`, `eff0efd`, `372dc86`, `afaed86`, and `086b2d6`.

## Attended UAT only

The remaining work is attended real-vendor and signed/notarized-app UAT. No
code or automated-test gap remains in the Task 8 scope.

DONE
