# Privacy and local data

Let It Brew has no account, cloud service, or telemetry. Session detection and
state stay on the Mac.

## What session records contain

Per-session records contain structural metadata used to decide whether the Mac
should stay awake:

- session ID and agent;
- Working or Idle state;
- project path;
- process ID when known;
- semantic activity token and lifecycle event; and
- timestamps.

`notification_type` is structural metadata. Let It Brew does not decode or
record notification prose, prompts, responses, reasoning, tool inputs, tool
outputs, other tool details, or final assistant text. Only `tool_name` is reduced
to the semantic activity token.

Nothing from session records is uploaded. An update check that you explicitly
start contacts GitHub for release metadata and, after confirmation, downloads
the release DMG and checksum.

## Local storage and agent configuration

| Location | Contents |
|---|---|
| `~/Library/Application Support/LetItBrew/sessions/` | Records for observed local sessions. |
| `~/Library/Application Support/LetItBrew/` | Connection registry, lease, and recovery state. |
| `/Library/Application Support/LetItBrew/` | Background-service recovery state for the system-wide sleep setting. |
| macOS user defaults | Pause, safety thresholds, closed-lid, and Launch at Login preferences. |
| `~/Library/Application Support/LetItBrew/agent-hook-targets.json` | The exact user-scoped configuration targets that Let It Brew owns. |
| `~/.claude/settings.json` | Claude Code user settings. Only Let It Brew-owned hook entries are changed after Connect. |
| `~/.codex/hooks.json` | Default Codex hook file. When `CODEX_HOME` is set, Let It Brew uses `<CODEX_HOME>/hooks.json`. |
| `~/.config/opencode/plugins/letitbrew.js` | Default OpenCode plugin. When `OPENCODE_CONFIG_DIR` is set, Let It Brew uses `<OPENCODE_CONFIG_DIR>/plugins/letitbrew.js`. |
| `~/.copilot/hooks/letitbrew.json` | Default GitHub Copilot CLI hook file. When `COPILOT_HOME` is set, Let It Brew uses `<COPILOT_HOME>/hooks/letitbrew.json`. |

`OPENCODE_CONFIG_DIR` selects an additional explicit configuration directory.
It does not replace OpenCode's standard configuration roots or other plugins.

Agent connections are opt-in. Let It Brew writes no hook configuration until you
choose **Connect**. It records the exact selected target so a later environment
change cannot redirect the connection. **Disconnect** removes only the entry or
plugin Let It Brew owns.

Malformed, unreadable, foreign, or unowned configuration is left alone and
reported as **Action needed**. Project, team, enterprise, and unrelated plugin
scopes are not changed.

## Removing local data

The supported uninstall action under **Settings → About** disconnects Let It
Brew's agent integrations, removes its settings and session records, unregisters
the background service, and moves the app to the Trash. If the app will not
launch, follow [Uninstalling by hand](UNINSTALL.md) in the documented order.
