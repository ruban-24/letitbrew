# Privacy and local data

Let It Brew has no account, cloud service, or telemetry. Session detection and
state stay on the Mac.

## What session records contain

Per-session records contain structural metadata used to decide whether the Mac
should stay awake:

- session ID and agent;
- Working, Waiting, or Idle state;
- project path;
- the agent's process ID when known, found from the hook's parent processes;
- semantic activity token and lifecycle event;
- for GitHub Copilot CLI, the path of its configuration folder; and
- timestamps.

The process ID is used to bring the session's terminal, editor, or agent app
forward when you click its menu row, to ignore a Waiting session whose agent
has exited, and to find the app whose input can answer an approval that sends
no hook. Let It Brew reads each ancestor's process ID, parent ID, and short
command name, never its arguments or environment. When no ancestor is a regular
app, as with a terminal host that runs detached from its app, it also reads
the executable path of the process at the root of that chain to find the app
bundle that holds it, when you click a row and while such an approval waits.
That path is not stored.

`notification_type` is structural metadata. Let It Brew does not decode or
record notification prose, prompts, responses, reasoning, tool inputs, tool
outputs, other tool details, or final assistant text. Only `tool_name` is reduced
to the semantic activity token. Question text and approval details are never
read; a Waiting record says only whether it waits for an answer or an approval.

To tell whether a Claude, Copilot, Gemini, or Qwen prompt you approved is
running, the app reads which processes that agent started, with each one's
process group and start time, from the macOS process table. It reads no
command lines, keys, clicks, or positions, needs no permission, and stores
nothing. It does this only while such a prompt is waiting.

GitHub Copilot CLI records Esc in its session log but sends no hook for it. While
a Copilot turn is active, the app therefore reads the last 256 KB of that
session's `session-state/<session>/events.jsonl` and decodes only each event's
`type` and `timestamp`, never prompts, responses, or tool details. Nothing from
the log is stored.

Nothing from session records is uploaded, except the agent name and project
folder name in phone alerts you set up. See [Alerts](#alerts).

Let It Brew checks GitHub for published release metadata about 30 seconds after
launch, no more than once every 24 hours. A manual check can also be started
from About. These requests include the app version in the HTTP User-Agent but
no agent names, project paths, prompts, code, repository contents, or session
records. Downloads begin only after you confirm an available update.

## Alerts

Alerts are off by default. Desktop alerts are macOS notifications shown on this
Mac and send nothing over the network.

Phone alerts make the only outbound request besides the update check. Nothing
is sent until you choose Set Up under **Settings → Alerts → On your phone** and
press Send Test.
Set Up generates a private random topic on the Mac, `letitbrew-` followed by 16
random lowercase letters and digits, and draws its QR code locally. Requests go
only to the server you chose, `https://ntfy.sh` by default, and only over HTTPS.
On a public server such as ntfy.sh, anyone who knows the topic can read its
alerts, so keep the topic private.

Each alert, and each Send Test, is one HTTPS `POST` to the server root with a
JSON body:

```http
POST https://ntfy.sh/
Content-Type: application/json

{
  "topic": "letitbrew-k3v9q2m7x1c8d4fz",
  "title": "Claude Code needs you",
  "message": "letitbrew · Waiting for your approval"
}
```

An `Authorization: Bearer <token>` header is added only when you set an access
token in Advanced. The request uses no cookies or cache and carries the
standard macOS User-Agent: the app's name and build number and the CFNetwork
and Darwin versions. A send that fails is retried once after 2 seconds and then
dropped.

The title and message are the alert's text and nothing else. They can contain:

- the agent's name, such as Claude Code or Codex;
- the project folder's name, the last part of its path, never the full path;
- for a held command, its command line, shortened to 60 characters, or
  `Process <pid>` for `letitbrew hold --pid`;
- whether the agent waits for an answer or an approval, how many minutes the
  work ran, and whether a held command succeeded or failed; and
- for a power or Wi-Fi alert, which rule stopped the hold, such as "Battery
  reached 20%.", or that Wi-Fi dropped.

With Hide project names on, the folder name is left out and a held command is
called "A held command". Alerts never include prompts, questions, responses,
reasoning, tool names, tool inputs or outputs, or file contents. The Send Test
message is "Let It Brew test" and "Phone alerts are working."

## Local storage and agent configuration

| Location | Contents |
|---|---|
| `~/Library/Application Support/LetItBrew/sessions/` | Records for observed local sessions. |
| `~/Library/Application Support/LetItBrew/holds/` | One record per running `letitbrew hold`: the process ID, the command line (shortened) or the PID it waits for, and its start time. Removed when the hold ends. |
| `~/Library/Application Support/LetItBrew/hold-results/` | One record per finished `letitbrew hold -- <command>`: its hold record, when it ended, and its exit status, used for the finished alert. Removed once the app has read it, or at the next launch if the app was not running. |
| `~/Library/Application Support/LetItBrew/manual-session.json` | The running manual keep-awake session: when it started, its deadline, and the boot it belongs to. Removed when it ends. |
| `~/Library/Application Support/LetItBrew/` | Connection registry, lease, and recovery state. |
| `/Library/Application Support/LetItBrew/` | Background-service recovery state for the system-wide sleep setting, and the per-source energy mode recorded before closed-lid Low Power Mode. |
| macOS user defaults | Pause, battery threshold, connected-power-only, Low Power Mode, closed-lid Low Power Mode, display-sleep, closed-lid, Launch at Login, and menu-bar icon preferences. |
| macOS user defaults (alerts) | Alert switches (`desktopAlerts`, `needsYouAlerts`, `finishedAlerts`, `stoppedForPowerAlerts`, `wifiDroppedAlerts`, `hideProjectNamesInAlerts`), the dismissed menu tip (`alertsTipDismissed`), and the phone alert setup: on or off (`phoneAlertsOn`), `alwaysSendToPhone`, the ntfy topic (`ntfyTopic`) and server (`ntfyServer`), and when a test was last sent (`ntfyTestSentAt`, `ntfyTestSent`). |
| Login Keychain item "Let It Brew ntfy access token" (service `com.ruban24.letitbrew.ntfy`) | The ntfy access token, only if you set one in Advanced. |
| `~/Library/Application Support/LetItBrew/agent-hook-targets.json` | The exact user-scoped configuration targets that Let It Brew owns. |
| `~/.claude/settings.json` | Claude Code user settings. Only Let It Brew-owned hook entries are changed after its watched switch is turned on. |
| `~/.codex/hooks.json` | Default Codex hook file. When `CODEX_HOME` is set, Let It Brew uses `<CODEX_HOME>/hooks.json`. |
| `~/.config/opencode/plugins/letitbrew.js` | Default OpenCode plugin. When `OPENCODE_CONFIG_DIR` is set, Let It Brew uses `<OPENCODE_CONFIG_DIR>/plugins/letitbrew.js`. |
| `~/.copilot/hooks/letitbrew.json` | Default GitHub Copilot CLI hook file. When `COPILOT_HOME` is set, Let It Brew uses `<COPILOT_HOME>/hooks/letitbrew.json`. |
| `~/.cursor/hooks.json` | Cursor user hooks. Only Let It Brew-owned entries are changed. |
| `~/.gemini/settings.json` | Gemini CLI user settings. Only Let It Brew-owned hook entries are changed. When `GEMINI_CLI_HOME` is set, Let It Brew uses `<GEMINI_CLI_HOME>/.gemini/settings.json`. |
| `~/.qwen/settings.json` | Qwen Code user settings. Only Let It Brew-owned hook entries are changed. When `QWEN_HOME` is set, Let It Brew uses `<QWEN_HOME>/settings.json`. |
| `~/.kimi-code/config.toml` | Kimi Code configuration. Only Let It Brew-owned `[[hooks]]` tables are changed. When `KIMI_CODE_HOME` is set, Let It Brew uses `<KIMI_CODE_HOME>/config.toml`. |

`OPENCODE_CONFIG_DIR` selects an additional explicit configuration directory.
It does not replace OpenCode's standard configuration roots or other plugins.

Agent connections are opt-in. Let It Brew writes no hook configuration until you
turn on that agent's watched switch. It records the exact selected target so a
later environment change cannot redirect the connection. Turning the watched
switch off removes only the entry or plugin Let It Brew owns.

Malformed, unreadable, foreign, or unowned configuration is left alone and
reported as **Action needed**. Project, team, enterprise, and unrelated plugin
scopes are not changed.

## Removing local data

The supported uninstall action under **Settings → About** disconnects Let It
Brew's agent integrations, removes its settings and session records, unregisters
the background service, and moves the app to the Trash. It also deletes the
ntfy access token from the Keychain. If the app will not launch, follow
[Uninstalling by hand](UNINSTALL.md) in the documented order, then delete the
"Let It Brew ntfy access token" item in Keychain Access if you set one.
