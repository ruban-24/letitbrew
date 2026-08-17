# Task 8 report

## Final green evidence

```text
swift test                                                       PASS (629 tests)
swift test --filter 'ExactFileSnapshotTests|ExactFileTargetTests|AgentInstallRegistryTests'
                                                                 PASS (58 tests)
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

The command contracts run only in throwaway `LETITBREW_TEST_HOME` roots. They
exercise all five adapters and the real CLI’s preflight/persist/commit/remove/
clear boundaries. The source gate rejects `/dev/fd`, Foundation path reads or
mutations, URL-based AtomicFile use after target selection, and the former
unsound newline-regex check has been replaced with fixed-string `rg` gates.

## Delivered scope

Claude, Codex, Cursor, OpenCode, and Copilot are managed through a strict
version-1 registry; exact snapshots/preparations; one-descriptor no-follow
capture; descriptor-bound quarantine/publication/removal; and an exact
five-agent CLI grammar. Test homes retain an anchored directory descriptor;
production symlink compatibility remains limited to the documented JSON
first-connect behavior. App refresh selects recorded target A before ambient
B, passes exact preparation to the hidden command, and treats healthy no-write
as unchanged.

The final safety matrix includes existing-target disappearance, same-size
restored-mtime edits, each metadata/digest/bytes mismatch including inode,
malformed JSON for all four JSON agents, unowned/symlinked OpenCode, registry
persist failure, vendor failure, removal failure, clear failure and real retry,
active replacement survival, all-five recorded-A versus foreign-B lifecycle,
full Cursor/Copilot foreign subtree preservation, doctor/watchdog, grammar,
and exact `SleepDisabled` baselines.

## Commit chain

Base implementation: `8e22b5b`.

Review/exact-target fixes: `c7c04e3`, `b959985`, `58cd630`, `758edf3`,
`006f61f`, `0b900cb`, `f786b4b`, `0e2310c`, `4b5b76a`, `ad9e02f`, `31a94db`,
`e2c1396`, `5d26279`, `e41688a`, `19e635c`, `d1b2096`, `b130512`, `db18a0b`,
`0fda5a8`, `410cbfa`, `d2c346e`, `4f30308`, `672bdf3`.

Descriptor-anchor work: `7704659`, `a4dc538`, `cd7793f`, `9579c78`,
`e8a0cab`, `eff0efd`, `372dc86`, `afaed86`, `086b2d6`, `24c4bcd`.

Final rereview fixes: `862e8f7`, `4898e6e`, `faa66d3`, `177a5e5`.
Final-fix rereview: descriptor-contained replacement seam, cross-line source
gate fixture, exact EINTR/short-read and absent-publish tests, and selected-A
app presentation/trust completion (recorded by the final fix commit).

## Self-review

All ten original findings and the FD design gap are closed in code and
automated evidence. No live configuration was read or changed. The only
remaining work is attended UAT with real vendor installations and a
signed/notarized app; neither is represented by these isolated tests.

Last-fix evidence adds the production-consumed AppCore presentation boundary
and independent multiline Data read/write/FileManager source-gate fixtures.

DONE
