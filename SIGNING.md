# Let It Brew signing and daemon build

Let It Brew's direct distribution uses Apple Developer Team `MV2UL94MDC`.

## Identifiers

| Product | Development | Production |
| --- | --- | --- |
| App | `com.ruban24.letitbrew.dev` | `com.ruban24.letitbrew` |
| Daemon | `com.ruban24.letitbrew.dev.daemon` | `com.ruban24.letitbrew.daemon` |

The separate development identifiers are a safety boundary. A development
copy must never share the production daemon label or Background Task
Management record.

## Development generate and build

```sh
xcodegen generate
xcodebuild -project LetItBrew.xcodeproj -scheme LetItBrew -configuration Debug \
  -derivedDataPath /private/tmp/letitbrew-xcode-derived \
  -allowProvisioningUpdates build
```

Keep DerivedData outside this repository. The workspace is stored in a
file-provider-managed folder, whose Finder metadata makes `codesign` reject a
bundle built inside it. The generated Xcode project is ignored; `project.yml`
is the source of truth.

## Direct-distribution release workflow

The release workflow does not install, launch, register, publish, tag, or upload
Let It Brew to a public download channel. It writes all build/archive evidence beneath
`/private/tmp` and requires a clean Git tree so one commit identifies every
release input.

Prerequisites controlled by the release owner:

- exactly one valid **Developer ID Application** identity for Team
  `MV2UL94MDC` in the signing keychain; and
- a previously stored `notarytool` Keychain profile. The scripts accept only
  its simple profile name. They never accept or record an Apple ID, password,
  API key, private-key path, or raw credential value.

### One-time release-owner setup

`Apple Development` proves a local development build. Direct GitHub Releases
distribution instead requires a `Developer ID Application` certificate, which
lets Gatekeeper identify Let It Brew as software signed by Apple Developer Team
`MV2UL94MDC`. Apple documents the Account Holder setup at
[Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates).

Create **Developer ID Application**—not Developer ID Installer—using the Apple
Developer certificate portal or Xcode. When using the portal, create the CSR on
this Mac, download the issued `.cer`, and open it to install it in the login
keychain. In Keychain Access → My Certificates, the certificate must expand to
show its private key. Verify that this command then reports exactly one matching
identity:

```sh
security find-identity -v -p codesigning
```

Notarization is Apple's automated malware and code-signing check. Save its
credential in Keychain under the profile name `letitbrew-release`; omit the
password option so `notarytool` asks for the app-specific password securely:

```sh
xcrun notarytool store-credentials letitbrew-release \
  --apple-id "YOUR_APPLE_ID" \
  --team-id MV2UL94MDC
```

Do not paste the Apple ID, app-specific password, certificate private key, or
Keychain export into this repository, an issue, a release log, or an agent
conversation. Apple describes the credential and ticket workflow in
[Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

Choose a new release workspace beneath `/private/tmp`. The build number remains
part of app metadata, evidence ZIPs, and the manifest; the final public
DMG name is stable by marketing version: `LetItBrew-<version>.dmg`.

```sh
letitbrew_version="$(awk -F': ' '/^[[:space:]]+MARKETING_VERSION:/ { gsub(/\"/, \"\", $2); print $2; exit }' project.yml)"
letitbrew_build="$(awk -F': ' '/^[[:space:]]+CURRENT_PROJECT_VERSION:/ { gsub(/\"/, \"\", $2); print $2; exit }' project.yml)"
letitbrew_release_root="/private/tmp/LetItBrewRelease-${letitbrew_version}-${letitbrew_build}-$(git rev-parse --short=12 HEAD)"

scripts/build-release-artifact.sh --output-root "$letitbrew_release_root"
scripts/create-release-dmg.sh "$letitbrew_release_root"
scripts/notarize-release.sh "$letitbrew_release_root" \
  --keychain-profile letitbrew-release \
  --timeout 30m
```

`build-release-artifact.sh` refuses root, a dirty tree, an existing/symlinked
workspace, output outside `/private/tmp`, or missing/ambiguous Developer ID
identity. It regenerates `LetItBrew.xcodeproj` from `project.yml`, archives and
exports with the exact 40-hex identity hash, and runs
`scripts/verify-artifact.sh <app> --release`. It also rejects
`get-task-allow=true`, verifies hardened runtime and a native CDHash on both
architectures of every executable, retains the `.xcarchive` and dSYMs, and
writes sorted version/build/commit/signature/SHA-256 evidence.

`create-release-dmg.sh` creates a signed compressed image containing exactly
`Let It Brew.app` and `Applications -> /Applications`; packages are forbidden. It
verifies the image, mounts it read-only, and reruns release verification against
the mounted app. This first image is pre-notarization evidence.

`notarize-release.sh` uses two bounded, resumable submissions:

1. submit the retained app ZIP without waiting, persist its response, UUID, and
   exact submitted SHA-256, then wait by UUID and retain/validate Apple's log;
2. staple and validate the app, rebuild the signed DMG from that stapled app,
   retain the exact submitted DMG bytes, then repeat submit/wait/log for the DMG;
3. staple and validate the final DMG, verify its signature and filesystem,
   assess the mounted app and DMG with Gatekeeper, and write final SHA-256 sums.

If a wait times out, rerun the same command with the same release workspace. It
resumes the recorded UUID rather than submitting again. An ambiguous submission
outcome is a refusal requiring evidence review; it is never converted into an
automatic resubmission. Stapling changes bytes, so submitted and final hashes
are recorded separately. Preserve the entire release workspace and Apple logs
with the release record. DMG and notarization transactions hold an atomic
per-workspace lock; a concurrent or interrupted owner is a refusal. Cleanup
removes the lock only when its exact ownership token still matches.

Even a successful local workflow is not distribution approval. Quarantine,
online/offline Gatekeeper behavior, clean-account installation, upgrade,
uninstall, and the exact downloaded DMG remain manual DIST gates. Publication
requires separate authorization.

## GitHub Releases handoff

The build and notarization scripts deliberately stop before publication. After
all FUNC, SAFE, and DIST gates pass, publish the final stapled
`LetItBrew-<version>.dmg`, its final `LetItBrew-<version>-SHA256SUMS`, and the
byte-identical `LetItBrew.dmg` website alias from the release workspace. The
stable GitHub Release must identify the same version/build
and link the source commit, Apache License 2.0, NOTICE, trademark policy,
release notes, SHA-256, and [GitHub Issues](https://github.com/ruban-24/letitbrew/issues).

Download the DMG back through GitHub Releases rather than testing the local
upload source. Record the release URL, downloaded SHA-256, exact source commit,
and UAT evidence in a local, non-repository maintainer record. GitHub credentials
and upload commands remain outside the manifest and must not be added to shell
history.

The Debug app contains a signed daemon and development-only launchd plist, but
does not call `SMAppService` during an ordinary launch. Registration is an
explicit test operation and refuses to run until the signed app is a direct
child of `/Applications`:

```sh
'/Applications/Let It Brew Dev.app/Contents/MacOS/LetItBrew' --register-daemon
```

The location guard runs before constructing or registering an `SMAppService`.
There is deliberately no status query in the app: status reads are not passive.
Use `sfltool dumpbtm` to inspect the real Background Task Management record.
If registration reports `SMAppServiceErrorDomain (1)`, inspect **System
Settings → General → Login Items & Extensions → App Background Activity** and
enable Let It Brew before retrying registration.

The standalone daemon target must keep both
`CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` and `ENTITLEMENTS_REQUIRED = NO`.
It has no app provisioning profile, so app-style development entitlements make
its live signature invalid in the root launchd context. Runtime identity first
validates the signature, then reads the Team ID from signing metadata or the
validated leaf certificate's Organizational Unit for entitlement-free tools.

Development-only live probes are explicit and never contact `SMAppService`:

```sh
'/Applications/Let It Brew Dev.app/Contents/MacOS/LetItBrew' --probe-daemon
'/Applications/Let It Brew Dev.app/Contents/MacOS/LetItBrew' --hold-daemon
```

The second command intentionally remains running. Killing that client must
restore `SleepDisabled` and remove the daemon's root-owned debt marker. Killing
the daemon itself while held must make launchd start a new process whose
RunAtLoad reconciliation restores the recorded prior value before serving XPC.

## Never overwrite a running signed binary

Quit Let It Brew and stop any `letitbrew watch` process before replacing an installed
binary. Never use `cp` to overwrite a running Mach-O file on macOS: modifying
its existing inode invalidates the code signature and later launches can be
killed by the operating system. Stage the replacement at a new path and rename
it atomically, or use the release installer/update mechanism.
