# Agent Hook Contracts

## Product boundary

Let It Brew observes local lifecycle hooks only. It does not enumerate agent
processes, inspect CPU use, search for installed executables, parse conversations,
or read Claude/Codex/OpenCode/Copilot prompt and response content.

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
- `permission.updated`, `permission.asked`, and `permission.v2.asked` map to
  PermissionRequest and Idle. `permission.replied` and
  `permission.v2.replied` return the session to Working for every reply.
- `question.asked` maps to Idle. `question.replied` and `question.rejected`
  return the session to Working.
- OpenCode v2 beta is not claimed by this release.

## GitHub Copilot CLI

- Config: `~/.copilot/hooks/letitbrew.json`, relocated by `COPILOT_HOME`.
- Sources: https://docs.github.com/en/copilot/reference/hooks-reference and
  https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
- Use PascalCase compatibility events for snake_case payloads: SessionStart,
  UserPromptSubmit, PermissionRequest, PreToolUse, PostToolUse, Notification,
  ErrorOccurred, Stop, and SessionEnd.
- PermissionRequest becomes Idle. PreToolUse becomes Idle for `ask_user`,
  `ask_user_question`, and `AskUserQuestion`; other tools become Working.
  PostToolUse returns a completed question to Working. Notification becomes
  Idle for `permission_prompt` and `elicitation_dialog`.
- `ErrorOccurred` is observational and its output is not processed. A payload
  with `recoverable: false` maps to Idle; `true`, missing, or malformed
  recoverability preserves the prior state so a continuing turn stays Working.
- The generated command discards hook output and unconditionally exits zero,
  so Let It Brew observes these events without allowing, denying, or blocking
  Copilot actions; execution tests prove both properties before release.
- Copilot cloud agent is out of scope.
