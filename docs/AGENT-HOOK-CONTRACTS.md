# Agent Hook Contracts

## Product boundary

Let It Brew observes local lifecycle hooks only. It does not enumerate agent
processes, inspect CPU use, search for installed executables, parse conversations,
or read Claude/Codex/Cursor/OpenCode/Copilot prompt and response content.

## Claude Code

- User config managed by Let It Brew: `~/.claude/settings.json`.
- Sources: https://code.claude.com/docs/en/hooks and
  https://code.claude.com/docs/en/settings.
- Mapping: `SessionStart`→SessionStart, `UserPromptSubmit`→UserPromptSubmit,
  `PreToolUse`→PreToolUse, `PostToolUse`→PostToolUse,
  `PermissionRequest`→PermissionRequest, `Notification`→Notification,
  `PreCompact`→PreCompact, `PostCompact`→PostCompact,
  `SubagentStart`→SubagentStart, `SubagentStop`→SubagentStop,
  `Stop`→Stop, `StopFailure`→StopFailure, `SessionEnd`→SessionEnd.
- `session_id` is the parent session ID. `agent_id` is the stable child ID
  for subagent hooks and is combined with the parent ID for an independent
  child record.
- `SessionStart` source `compact`, `PreCompact`, and `PostCompact` preserve
  Working. A nonempty `background_tasks` array on Stop preserves Working;
  an empty or absent array makes Stop Idle. `session_crons` are not treated
  as current work.
- Permission events preserve prior state. API-error turns use `StopFailure`;
  user-interrupted turns have no immediate documented terminal hook.
- Interactive settings-file hooks, including user hooks, are held until the
  workspace is trusted. The connection UI can prove owned configuration,
  not trust for every future workspace.

## Codex

- User config managed by Let It Brew: `~/.codex/hooks.json`, relocated by
  `CODEX_HOME`.
- Source: https://learn.chatgpt.com/docs/hooks.
- Mapping: `SessionStart`→SessionStart, `UserPromptSubmit`→UserPromptSubmit,
  `PreToolUse`→PreToolUse, `PostToolUse`→PostToolUse,
  `PermissionRequest`→PermissionRequest, `PreCompact`→PreCompact,
  `PostCompact`→PostCompact, `SubagentStart`→SubagentStart,
  `SubagentStop`→SubagentStop, `Stop`→Stop, `SessionEnd`→SessionEnd.
- `session_id` is the parent session ID for subagent hooks. Combine it with
  `agent_id` for an independent child record.
- `SessionStart` source `compact`, `PreCompact`, and `PostCompact` preserve
  Working. Permission waits preserve prior state.
- Non-managed hooks must be reviewed and trusted in Codex before they run.

## Cursor local desktop and CLI

- User config managed by Let It Brew: `~/.cursor/hooks.json`. Cursor also has
  other project/team/enterprise hook scopes; Let It Brew does not mutate them.
- Sources: https://cursor.com/docs/hooks,
  https://cursor.com/docs/reference/third-party-hooks, and
  https://cursor.com/changelog/cli-jan-16-2026
- Desktop mapping: `sessionStart`→SessionStart,
  `beforeSubmitPrompt`→UserPromptSubmit, `preToolUse`→PreToolUse,
  `postToolUse`→PostToolUse, `subagentStart`→SubagentStart,
  `subagentStop`→SubagentStop, `stop`→Stop, `sessionEnd`→SessionEnd.
- Cursor CLI documents hooks for session start/end, prompt submission, and
  stop. The tool and subagent mappings above are documented desktop inputs,
  not supported CLI observations until UAT establishes them.
- Cursor desktop and Cursor CLI are separate validation surfaces. Desktop
  documentation does not prove CLI event parity. Release UAT must exercise and
  record every selected event independently on both surfaces, including the
  tested Cursor versions. Connection or configuration ownership does not prove
  that either surface emitted every mapped event.
- `conversation_id` is the stable session ID for ordinary events;
  `session_id` is accepted for session lifecycle events.
- `parent_conversation_id` plus `subagent_id` identifies an independent
  Cursor subagent, including asynchronous subagents that outlive a parent turn.
- Cursor has no documented permission-request lifecycle event. The prior
  state remains unchanged until a later hook establishes a transition.
- Cursor Tab and Cloud Agents are out of scope.

## OpenCode stable 1.x

- Default plugin: `~/.config/opencode/plugins/letitbrew.js`.
  `OPENCODE_CONFIG_DIR` selects an additional config directory; when present,
  Let It Brew manages its plugin beneath that explicit directory without
  claiming the standard directory stops loading.
- Sources: https://opencode.ai/docs/config/,
  https://opencode.ai/docs/plugins/, and
  https://github.com/anomalyco/opencode/blob/v1.18.3/packages/sdk/js/src/gen/types.gen.ts
- Mapping: `session.created`→SessionStart; `session.status` busy/retry→
  UserPromptSubmit; `session.status` idle and `session.idle`→Stop;
  `session.deleted`→SessionEnd.
- Stable v1.18.3 emits `permission.updated` and `permission.replied`; current
  docs also define `permission.asked`. All three preserve prior state, and
  UAT must record which spellings were actually observed for the tested
  OpenCode version; no runtime-emission claim is made until then.
- OpenCode v2 beta is not claimed by this release.

## GitHub Copilot CLI

- Config: `~/.copilot/hooks/letitbrew.json`, relocated by `COPILOT_HOME`.
- Sources: https://docs.github.com/en/copilot/reference/hooks-reference and
  https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
- Use PascalCase compatibility events for snake_case payloads:
  SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd.
- Do not install `PreToolUse`: command failures on that control hook are
  fail-closed. The selected observational events are sufficient for
  Working/Idle only if the generated command is silent and unconditionally
  exits zero; execution tests must prove both properties before release.
- `ErrorOccurred` is not installed in v0.6.0; an error path without
  `SessionEnd` relies on the stale-record backstop or Stop Tracking.
- Copilot cloud agent is out of scope.
