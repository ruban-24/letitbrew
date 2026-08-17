# Task 8 report

## Final evidence

```text
swift test                                                       PASS (611 tests)
swift test --filter Task-8 focused adapter/transaction/target suite PASS (130 tests)
swift build                                                      PASS
scripts/test-agent-hook-contracts.sh <absolute CLI>              PASS (repo root)
scripts/test-uninstall-safety.sh <absolute CLI>                  PASS (repo root)
/private/tmp/.../test-agent-hook-contracts.sh <absolute CLI>    PASS
/private/tmp/.../test-uninstall-safety.sh <absolute CLI>        PASS
xcodegen generate                                                PASS
xcodebuild -project LetItBrew.xcodeproj -scheme LetItBrew
  -configuration Debug build CODE_SIGNING_ALLOWED=NO            PASS
git diff --check                                                 PASS
```

The contract scripts include an automated source gate that rejects Task 8 CLI
use of `/dev/fd`, `Data(contentsOf:)`, `Data.write(to:)`, Foundation file
mutation, and URL-based AtomicFile operations after target selection.

## Delivered scope

The hook-only CLI manages Claude, Codex, Cursor, OpenCode, and Copilot through
strict version-1 registry JSON; exact snapshot/preparation values; descriptor
bound capture, publication, quarantine, and removal; and an optional exact
five-agent grammar. Test-home commands retain one no-follow root descriptor
and use descendant `*at` operations. Registry, install, uninstall, doctor,
and `prepare-exact` retain selected targets/captures through their transaction
boundaries. First-connect JSON links resolve once under the anchored root;
recorded final links and OpenCode final links refuse.

## Commit chain

Base implementation: `8e22b5b`.

Review and exact-target fixes: `c7c04e3`, `b959985`, `58cd630`, `758edf3`,
`006f61f`, `0b900cb`, `f786b4b`, `0e2310c`, `4b5b76a`, `ad9e02f`, `31a94db`,
`e2c1396`, `5d26279`, `e41688a`, `19e635c`, `d1b2096`, `b130512`, `db18a0b`,
`0fda5a8`, `410cbfa`, `d2c346e`, `4f30308`, `672bdf3`.

Descriptor-anchor completion: `7704659`, `a4dc538`, `cd7793f`, `9579c78`,
`e8a0cab`, `eff0efd`, `372dc86`, `afaed86`, `086b2d6`.

## Self-review

All ten review findings are closed: coherent one-descriptor evidence;
strict registry wire format/private publication/baselines; no-follow
test-home containment; recorded-target symlink refusal; app preparation
handoff coverage; independent doctor/watchdog states; stale-registry removal
semantics; preparation/fault matrices; and shell/OpenCode/uninstall contracts.
The FD delta is closed with retained directory descriptors, route
revalidation, descriptor-only Task 8 persistence/removal, deterministic
quarantine/temp races, all-five parent-symlink coverage, and a source gate.

## Remaining attended UAT

No live vendor config, live agent executable, signed/notarized app, or real
customer home directory was touched. An attended signed-app pass against real
Claude, Codex, Cursor, OpenCode, and Copilot remains required.

DONE
