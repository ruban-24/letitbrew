# Support

Let It Brew is maintained on a best-effort basis, without a response-time or
compatibility commitment.

## Before opening an issue

Confirm that:

- you are running the newest published release;
- the affected session is local, not remote, cloud-hosted, or over SSH;
- you checked the agent's connection state in **Settings → Agents**;
- Let It Brew is not paused and no battery or thermal safety gate is active; and
- you restarted a session that was already open when its hooks changed.

## Troubleshooting

**A Working session is not showing up.** Check the agent's connection state in
**Settings → Agents**. Confirm the session is local and restart it if it was
already open when the hooks changed.

**An agent says Action needed or Couldn't connect.** Let It Brew left the agent's
configuration untouched because it could not safely verify it. Review the
agent's user-scoped path in [Privacy and local data](docs/PRIVACY.md), fix any
malformed configuration if appropriate, then choose **Check Again**.

**Codex asks me to run `/hooks`.** Codex requires explicit trust for the hooks
Let It Brew installs. Run `/hooks` inside Codex, trust the Let It Brew entries,
then return to **Settings → Agents** and choose **Check Again**.

**My Mac sleeps while an agent appears to be running.** Confirm the session is
listed as **Working**. Let It Brew releases its hold when a session becomes Idle,
the app is paused, or a battery, thermal, or power-status safety gate requires
the Mac to sleep.

**A session stays Working after the agent stops.** Choose **Stop Tracking** for
that session to release it immediately. Let It Brew relies on lifecycle hooks,
so a missing terminal event can leave a record Working until the 12-hour stale
record backstop removes it.

**Closed-lid support is unavailable.** Confirm Let It Brew is running directly
from `/Applications/Let It Brew.app`. Then check **System Settings → General →
Login Items & Extensions → App Background Activity** for the background-service
approval.

**Can Let It Brew follow remote, cloud, or SSH sessions?** No. It observes only
supported local sessions running on the same Mac.

## Installation, updates, and removal

**Why must the app be in `/Applications`?** The privileged closed-lid service is
tied to the exact signed app at `/Applications/Let It Brew.app`. Running from a
subfolder, mounted DMG, or Downloads disables closed-lid management.

**Do settings survive an update?** Yes. Updating replaces the app bundle while
leaving preferences, agent connections, and session data in place. Update checks
are manual; there is no background polling.

**Is Let It Brew available through Homebrew or the App Store?** No. The signed,
notarized DMG on [GitHub Releases](https://github.com/ruban-24/letitbrew/releases/latest)
is the only install channel.

**What if the app will not launch when I need to uninstall it?** Follow the
[manual uninstall procedure](docs/UNINSTALL.md). The order matters because the
background service must be unregistered while its owning app is still present.

## Safety and privacy

Ordinary use does not need admin rights. Closed-lid support installs a
privileged background service after you approve it in System Settings. Declining
that approval leaves ordinary open-lid holding available.

Let It Brew has no account, cloud service, or telemetry. It never uploads agent
sessions or project data. A manual update check contacts GitHub for release
metadata and, after confirmation, downloads the DMG and checksum. See
[Privacy and local data](docs/PRIVACY.md) and the
[architecture document](docs/ARCHITECTURE.md) for details.

If Let It Brew crashes during an open-lid hold, macOS releases the app's power
assertion with the process. For closed-lid support, the background service
restores the recorded `SleepDisabled` value after a crash or reboot.

## Reporting a problem

Use [GitHub Issues](https://github.com/ruban-24/letitbrew/issues) for
reproducible bugs and scoped feature requests. Include:

- the Let It Brew version and build;
- the macOS version and Mac model;
- clear reproduction steps; and
- the visible state or error message.

Do not include private project contents, prompts, agent responses, unrelated
agent configuration, credentials, or logs containing any of them.

Report security or power-safety vulnerabilities through the private reporting
link in [SECURITY.md](SECURITY.md), not a public issue.
