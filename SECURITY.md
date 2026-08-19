# Security policy

## Supported versions

Security and power-safety fixes are provided for the newest published release.
Older releases are not patched — update through
**Settings → About → Check for Updates…** or install the latest
[signed DMG](https://github.com/ruban-24/letitbrew/releases/latest).

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/ruban-24/letitbrew/security/advisories/new)
for this repository. If that option is unavailable, open a minimal issue asking
for a private reporting channel — do not include exploit details, credentials,
private project paths, agent configuration, or sensitive logs in a public issue.

Please include the Let It Brew version and build, macOS version, Mac model, and
the smallest safe reproduction.

## Reporting a power-safety problem

Let It Brew's privileged background service changes the system-wide
`SleepDisabled` setting. A bug that leaves that value wrong is a safety problem,
not a cosmetic one.

If you suspect one:

1. Keep physical access to the Mac and save your work.
2. Choose **Allow Mac to Sleep**, then quit Let It Brew.
3. Record the original and current `SleepDisabled` values **without forcing
   either**:

   ```sh
   pmset -g | grep SleepDisabled
   ```

Forcing the value to `0` destroys the evidence and assumes your Mac started with
sleep enabled, which may not be true. Report the reading instead.

## What not to publish

Do not publish Apple credentials, signing certificates, private keys,
notarization credentials, or unrelated agent configuration — in an
issue, a pull request, a release log, or an agent conversation.
