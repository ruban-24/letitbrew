# Release and acceptance scripts

These scripts are release gates for the production app installed directly at
`/Applications/Let It Brew.app`. They never read `SMAppService.status`. Service
Management is performed only by command modes of that signed installed app.

An unreadable or ambiguous power value, unsigned/misidentified bundle, command
timeout, stale daemon identity, unresolved reconciliation, duplicate process, or
incomplete observable test is nonzero. None is converted into a default value.

## Signed-app command contract

The upgrade and acceptance scripts expect the app to provide:

- `--register-daemon`: wait for the Service Management registration operation to
  complete and exit nonzero on failure.
- `--unregister-daemon`: wait for unregister and daemon termination to complete;
  exit nonzero on failure.
- `--probe-daemon --json`: perform the authenticated XPC handshake and emit one
  JSON object containing `protocolVersion` (integer), `marketingVersion`
  (string), `build` (string), `buildIdentity` (the running daemon's native
  signed CDHash), `reconciliationReady` (boolean), and `message` (string).
- `--prepare-daemon-upgrade --json`: refuse active hold owners, reconcile durable
  debt, and emit the same strict identity fields plus
  `sleepDisabledBaseline` (`0` or `1`). Success means the baseline is readable,
  exact, and no restore is owed.
- `--prepare-update --json`: classify actual service presence without reading a
  preference or `SMAppService.status`. A registered service is reconciled and
  emits `daemonState=registered`, strict identity fields, and the exact
  `sleepDisabledBaseline`; affirmative absence emits `daemonState=absent` and
  `reconciliationReady=true`. Every ambiguous connection failure is nonzero.

The expected identity is obtained from `codesign -dvvv` on the verified embedded
daemon after signing. It is not a source or Info.plist version string.

An installed pre-identity candidate is supported only as the *old* side of the
first migration: its exact legacy authenticated
`Let It Brew daemon protocol vN ready.` probe may establish preflight and rollback
health for that restored old bundle. Legacy output can never validate the new
candidate.

## `lib-power-baseline.sh`

`baseline_read_sleepdisabled` accepts exactly one canonical
`SleepDisabled 0`/`SleepDisabled 1` entry from a successful `pmset -g`. Missing,
duplicated, conflicting, or malformed entries are refusals. Every live operation
records and compares the exact value; a user baseline of `1` remains `1`.

## `verify-artifact.sh <Let It Brew.app> [--release]`

Verifies the production product before installation:

- exact app/daemon/helper signing identifiers and Team ID `MV2UL94MDC`;
- universal `arm64` and `x86_64` executables;
- strict signatures, hardened runtime, and native CDHashes;
- exact launch-daemon plist label, associated app, program, Mach service,
  RunAtLoad, and KeepAlive contract;
- exact ordinary-file `UpdateSupport` payload (`run-update.sh`,
  `upgrade-installed-app.sh`, `verify-artifact.sh`, and
  `lib-power-baseline.sh`) with fixed executable/data modes;
- entitlement-free daemon/helper, icon and `LSUIElement` metadata, app/helper
  version consistency, and no UserNotifications linkage.

`--release` additionally requires Developer ID Application authority and secure
timestamps. The upgrader requires decimal `CFBundleVersion` values and refuses a
candidate unless its build is strictly greater than the installed build.

## Direct-distribution scripts

These scripts create local release evidence only. They do not install or launch
the app, manage its services, modify power state, tag Git, publish a release, or
upload to a distribution channel.

### `build-release-artifact.sh [--output-root /private/tmp/new-directory]`

Requires a non-root user, a completely clean tracked/untracked Git tree, and
exactly one valid Developer ID Application identity for Team `MV2UL94MDC`.
The selected full 40-hex identity SHA-1 is pinned for archive and export; an
identity common name or automatic certificate selector is not accepted.

The script:

1. reads the dotted marketing version and decimal build from `project.yml`;
2. generates `LetItBrew.xcodeproj` with XcodeGen and confirms generation did not
   change release inputs;
3. archives a universal Release app with DerivedData and `.xcarchive` beneath
   the new `/private/tmp` workspace;
4. exports with `method=developer-id`, manual signing, the exact identity hash,
   and Team ID, without `-allowProvisioningUpdates`;
5. runs `verify-artifact.sh --release`, rejects main-app `get-task-allow=true`,
   and checks hardened runtime/native CDHash for both architectures of app,
   daemon, and helper; and
6. retains the archive/dSYMs, app notary ZIP, and a sorted manifest containing
   version, build, full commit, identity, per-slice CDHashes, and SHA-256s.

The default workspace is
`/private/tmp/LetItBrewRelease-<version>-<build>-<12-char-commit>`. Any explicit
workspace must be new, non-symlinked, and beneath `/private/tmp`.

### `create-release-dmg.sh <release-root>`

Creates the marketing-version filename `LetItBrew-<version>.dmg`. The
compressed HFS+ image contains exactly a release-verified `Let It Brew.app` and an
`Applications -> /Applications` symlink; `.pkg` content is refused. The DMG is
signed with the exact manifest identity, signature/image-verified, mounted
read-only, and its contained app is release-verified again.

The first call creates pre-notarization evidence. The notarization script alone
uses the guarded `--replace-after-app-staple` mode to rebuild the final signed
DMG from the validated stapled app.

### `notarize-release.sh <release-root> --keychain-profile <name> [--timeout 30m]`

The only authentication input is a simple name for an existing `notarytool`
Keychain profile. Raw Apple IDs, passwords, API keys, issuer IDs, private-key
paths, and unknown flags are not accepted or recorded.

The exact order is app-ZIP submit (no wait), journal UUID/hash, bounded wait,
Apple-log validation, app staple/validation/reverification, final DMG rebuild,
retained submitted-DMG copy, DMG submit, journal UUID/hash, bounded wait/log,
then final DMG staple and full validation. Apple logs must explicitly have no
issues. A timed-out invocation resumes its saved UUID on rerun; it never blindly
resubmits. The final manifest distinguishes submitted hashes from post-staple
hashes and `LetItBrew-<version>-SHA256SUMS` contains exactly the final DMG and
manifest, one per line as `64 lowercase hex`, two spaces, and the basename. The
in-app updater parses that exact DMG entry. Successful notarization also creates
`LetItBrew.dmg` as a byte-identical, mode-0600 alias for the website's permanent
`/releases/latest/download/LetItBrew.dmg` URL. The alias is not added to the
checksum file and does not change the updater's versioned asset contract.
DMG and notarization transactions use an atomic per-release-root directory lock;
concurrent use refuses, and cleanup removes only its matching owner token.

The final checks include `stapler`, strict code-signature and `hdiutil`
validation, a read-only mount with the exact two-item payload, release
verification of the contained app, and `spctl` assessments. Clean-machine,
quarantine, offline staple, download-channel, and publication checks remain
manual and out of scope.

```bash
letitbrew_version="$(awk -F': ' '/^[[:space:]]+MARKETING_VERSION:/ { gsub(/\"/, \"\", $2); print $2; exit }' project.yml)"
letitbrew_build="$(awk -F': ' '/^[[:space:]]+CURRENT_PROJECT_VERSION:/ { gsub(/\"/, \"\", $2); print $2; exit }' project.yml)"
letitbrew_release_root="/private/tmp/LetItBrewRelease-${letitbrew_version}-${letitbrew_build}-$(git rev-parse --short=12 HEAD)"

scripts/build-release-artifact.sh --output-root "$letitbrew_release_root"
scripts/create-release-dmg.sh "$letitbrew_release_root"
scripts/notarize-release.sh "$letitbrew_release_root" \
  --keychain-profile letitbrew-release --timeout 30m
```

When publishing the GitHub release, upload all three public assets from that
workspace: `LetItBrew-<version>.dmg`,
`LetItBrew-<version>-SHA256SUMS`, and `LetItBrew.dmg`. GitHub's latest-release
redirect then gives the website a permanent direct download while the in-app
updater continues to select and verify the two versioned assets.

## In-app updater transaction

**Settings → About → Check for Updates…** drives the existing guarded upgrade;
it does not replace the app bundle directly. The app accepts only the latest
published GitHub release metadata, exact versioned DMG/checksum asset names,
bounded HTTPS downloads, matching SHA-256 evidence, a valid signed image,
Gatekeeper acceptance, the exact two-item DMG layout, and a release-verified app
whose decimal build is strictly newer.

The app stages the candidate, verifies its executable identity again, copies
the four updater support files only from its own signed bundle into a private
0700 workspace, records and rechecks their hashes, then launches the runner and
quits. Nothing from the downloaded DMG is executed.

### `run-update.sh`

This is an embedded bridge, not a user command. It accepts structured candidate,
old-app PID, result, and log paths confined to the private update workspace. It
waits boundedly for that exact installed app process to disappear, then invokes
`upgrade-installed-app.sh --relaunch --preserve-daemon-state`. Only after the
transaction and any rollback handlers finish does it publish a new 0600
`result.json` without overwriting an existing path. The relaunched app polls
that record for up to 60 seconds, removes a proven-success download workspace,
and preserves failure diagnostics until the user dismisses them.

## `upgrade-installed-app.sh <new-Let It Brew.app> [--relaunch] [--preserve-daemon-state]`

The only destination is `/Applications/Let It Brew.app`. Run as the logged-in user,
never root. The ordinary app and command-mode processes must already be stopped.
`--relaunch` is the only permission to start one ordinary instance afterwards.

Ordered transaction:

1. Acquire an identity-matched exclusive lock and create a random sibling
   workspace on the `/Applications` volume.
2. Verify source and staged candidates, compare executable SHA-256 manifests,
   identifiers, Team ID, versions/builds, and native daemon CDHash. Refuse a
   same, older, or non-decimal candidate build.
3. In updater mode, ask the old signed app to classify actual daemon state. A
   registered daemon must reconcile and return strict identity plus its exact
   baseline; an affirmatively absent daemon is recorded as absent after two
   stable baseline reads. The closed-lid preference is never consulted. The
   legacy manual path requires the daemon and retains its bounded exception for
   an old pre-identity candidate.
4. For registered state, unregister the old service and verify both launchd job
   and exact process are absent. For absent state, prove they were already
   absent. Recheck the exact baseline in either case.
5. Rename old bundle to backup and verified stage into place. No live Mach-O is
   overwritten.
6. Reverify installed hashes/signatures and register the exact renamed bundle
   with LaunchServices. Registered state registers from that installed binary,
   requires exactly one current launchd daemon, and compares strict probe JSON
   to the installed daemon's native CDHash/version/build. Absent state leaves
   the daemon unregistered and proves the job and process remain absent.
7. Recheck the exact baseline, optionally relaunch exactly one ordinary app, and
   only then delete the backup.

Every post-swap failure stops any failed new service, verifies absence, moves the
failed new bundle to quarantine, atomically restores the old bundle, restores
and probes the old service only when its recorded state was registered (or
proves continued absence otherwise), and verifies the exact baseline. If
rollback cannot be proven, all remaining bundles and their exact recovery paths
are preserved.
The EXIT trap never unconditionally deletes a backup.

```bash
scripts/upgrade-installed-app.sh '/path/to/verified/Let It Brew.app'
scripts/upgrade-installed-app.sh '/path/to/verified/Let It Brew.app' --relaunch
```

## `verify-installed-app.sh`

Runs only against `/Applications/Let It Brew.app` and requires exactly one ordinary
app plus one current daemon. It verifies artifact identity, strict JSON handshake
against the installed native CDHash/version/build, diagnostic process isolation,
bounded command completion, hold acquire/release, and exact final baseline.

The hold client has EXIT/INT/TERM/HUP cleanup. If entry `SleepDisabled` is `1`,
the transition is unobservable: non-mutating gates still run, but the script
prints `INCOMPLETE` and exits `2`, never `0`.

```bash
scripts/verify-installed-app.sh
```

## `test-hook-safety.sh [cli]`

Exercises hook install/repair/uninstall against a throwaway `LETITBREW_TEST_HOME`.
It must not touch live Claude/Codex configuration or move the exact power
baseline. This is independent of the production bundle transaction.

## `test-session-pressure.sh`

Runs the deterministic concurrent-session correctness matrix for 1, 2, 10, 15,
50, and 100 simultaneous sessions. One hundred sessions are the qualified
automated load. The matrix verifies independent JSON records, full-path and
agent attribution, isolation when one session stops, last-Working-session hold
release, corrupt-record isolation, repository grouping, and menu presentation.
Its session data, SwiftPM scratch build, and module caches use isolated locations
beneath `/private/tmp`; it does not inspect user agent configuration or
Application Support. The suite prints
`METRIC session-pressure-100-seconds=<seconds>` for attended performance review,
but timing does not make the hardware-independent correctness test fail.
`test-session-pressure-guard.sh` injects an unsafe `mktemp` result and confirms
the wrapper refuses before constructing cache paths or invoking Swift.

## `test-uninstall-safety.sh [cli]`

Exercises the filesystem effects of the in-app uninstall against a throwaway
`LETITBREW_TEST_HOME`: Let It Brew-owned hook entries removed, the user's own
configuration preserved semantically, and a malformed file left byte-identical.
It must not touch live Claude/Codex configuration or move the exact power
baseline.

The daemon gates, the data-directory deletion, the preferences wipe, and the
app's self-trash all happen in the app process rather than in this helper. They
are attended procedures and are out of scope here. A no-op helper stub
confirmed the hook-presence and malformed-refusal checks fail when nothing is
installed.

## Isolated shell tests

`scripts/tests/upgrade-transaction-tests.sh` sources the transaction and replaces its
command adapters inside temporary directories. Production has no environment
flag that enables fakes. The harness covers strict baseline parsing for 0/1,
pre-swap refusal, installed verification failure, registration failure, strict
probe failure, phase-aware rollback, backup lifetime, incomplete acceptance
status, bounded timeout, and exact hold-client cleanup. It never addresses
`/Applications`, launchd, Service Management, or real `pmset`.

`scripts/tests/direct-distribution-tests.sh` uses the same source-and-adapter
pattern for the release workflow. It proves root/dirty/identity/path refusals,
exact archive/export/package/notary ordering, Developer ID SHA-1 pinning,
entitlement and per-slice gates, the exact DMG payload, named-profile-only
authentication, app-staple-before-final-DMG order, failure short-circuiting,
identity-matched lock cleanup and concurrent-use refusal, UUID persistence,
timeout resume without resubmission, and final evidence contracts. It never
invokes real Xcode, signing, disk-image, notarization,
stapling, Gatekeeper, installed-app, service, or power commands.

```bash
scripts/tests/upgrade-transaction-tests.sh
scripts/tests/direct-distribution-tests.sh
```

## `public-source-tests.sh`

Checks that a public source snapshot contains no tracked internal design or
planning paths, root agent artwork, broken local README image links, stale 0.5.0
metadata, or pre-release publication instructions. It reads only tracked files
and Git metadata.

```bash
scripts/tests/public-source-tests.sh
```
