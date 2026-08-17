# Contributing to Let It Brew

Thanks for looking. Let It Brew is a macOS menu-bar app with a privileged
background service that changes a system-wide sleep setting, so contributions
are held to a slightly higher bar than usual: small, focused changes with
explicit safety evidence.

## What's welcome

| | |
|---|---|
| **Bug fixes** | Open a PR directly. |
| **Documentation** | Open a PR directly. |
| **Features and behavior changes** | **Open an issue first.** |
| **Release-process changes** | **Open an issue first.** |

The scope gate on features isn't bureaucracy — this app deliberately has no
power modes, idle-grace timers, or activity tuning, and that restraint is the
product. A feature PR that arrives without an agreed scope is likely to be
declined after you've already done the work. An issue costs you five minutes and
saves you that.

Please don't include credentials, private project contents, real agent
configuration, or local release artifacts in an issue or PR.

## Before you start

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). It's short, and it explains
why the daemon exists and what the app is and isn't allowed to assume about it.

Three invariants that come up in almost every review:

- **Never read `SMAppService.status`.** Status reads are not passive. Use
  authenticated daemon health instead.
- **Never overwrite a running signed executable.** Stage, verify, stop, rename.
- **Preserve the exact readable `SleepDisabled` baseline.** An unreadable value
  is an error, not `0`.

## Building

The app target builds through a generated Xcode project — `project.yml` is the
source of truth and `LetItBrew.xcodeproj` is gitignored.

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project LetItBrew.xcodeproj -scheme LetItBrew -configuration Debug build
```

Keep DerivedData outside this repository — see [SIGNING.md](SIGNING.md) for why.

### If you fork this

`BackgroundServiceEligibility.expectedTeamIdentifier` is hardcoded to Apple
Developer Team `MV2UL94MDC`. That check is load-bearing: it's how the app refuses
to manage a background service it can't prove is its own.

A fork signed with a different team will build and run, but closed-lid support
will refuse to register. To make it work in your fork, change that constant and
the identifiers in `project.yml` to your own. Please don't ship a build that
keeps this project's Team ID or bundle identifiers. Use a distinct product name
and icon, and see [TRADEMARKS.md](TRADEMARKS.md) for the brand-use boundary.

## Testing

```sh
CLANG_MODULE_CACHE_PATH=/private/tmp/LetItBrewContribution-ClangCache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/LetItBrewContribution-SwiftPMCache \
swift test

scripts/tests/upgrade-transaction-tests.sh
scripts/tests/update-runner-tests.sh
scripts/tests/direct-distribution-tests.sh
```

These are what CI runs, and they're what a PR needs to pass.

Know what they don't cover: `Sources/LetItBrewApp/` is not a SwiftPM target, so
`swift test` never executes the live update, uninstall, or SwiftUI paths. If your
change touches those, say so in the PR — a maintainer runs the attended checklist
in [docs/ATTENDED-UAT.md](docs/ATTENDED-UAT.md).

Live daemon, power, lid, reboot, signing, notarization, and installation tests
require attended procedures and are not ordinary pull-request checks. If a safety
or power test fails, stop with physical access to the Mac, preserve the original
`SleepDisabled` baseline, and record the exact reproduction. Stop using the
affected feature until it's understood.

## Pull requests

Describe the user-visible change, the failure mode it addresses, the tests you
ran, and any remaining manual UAT. Safety-critical tests must assert exact state
and must not silently discard missing evidence.

By contributing, you agree that your contribution is licensed under Apache License 2.0 and that you have the right to submit it.
