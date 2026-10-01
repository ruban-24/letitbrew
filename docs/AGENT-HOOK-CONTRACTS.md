# Agent Hook Contracts

## Product boundary

Let It Brew observes local lifecycle hooks only. It does not enumerate agent
processes, inspect CPU use, search for installed executables, parse conversations,
or read Claude/Codex/OpenCode/Copilot/Pi prompt and response content.

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
  Working. On Stop, background tasks with `completed`, `failed`, `killed`,
  `cancelled`, `canceled`, or `idle` status do not preserve Working. Any
  other, missing, or unrecognized status conservatively preserves Working.
  An empty or absent array makes Stop Idle. Only status is read; task prose
  and commands are discarded. `session_crons` are not treated as current work.
- `SubagentStop` removes its child record. If it explicitly reports a
  `background_tasks` snapshot with no potentially working tasks, it also makes
  a parent still Working from `Stop` Idle. An absent/null snapshot cannot prove
  completion. A newer foreground event prevents this parent reconciliation.
- Parent `SessionEnd` removes the parent's children as well. A bounded family
  lock serializes child updates with termination; terminal markers prevent late
  hooks from recreating that family until `SessionStart` or `UserPromptSubmit`.
  Older observations cannot close a newer parent or child. Other sessions and
  agents are unaffected. Readers exclude children of an ended parent even if
  cleanup was interrupted; a precise reopen timestamp keeps leftovers from a
  previous run excluded after resume. Missing/unreadable parent state does not
  itself suppress a child's work.
- Permission events preserve prior state. API-error turns use `StopFailure`;
  user-interrupted turns have no immediate documented terminal hook.
  Permission approval has no matching immediate hook to resume a hold before
  the tool executes, so releasing on the prompt would risk sleeping mid-tool.
  Without a later authoritative event, interrupted turns and stopped parents
  with unreported background completion can remain Working until the existing
  12-hour expiry. Silence alone does not prove work ended. A background task
  still reported as running (including a monitor) continues to preserve Working.
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

## Pi (development branch, 0.87.1+)

- Owned extension: `~/.pi/agent/extensions/letitbrew.ts`, relocated by
  `PI_CODING_AGENT_DIR` when that variable is present in Let It Brew's
  environment. Finder-launched apps do not inherit shell-only overrides.
- Source: https://pi.dev/docs/latest/extensions. Verified against the installed
  `@earendil-works/pi-coding-agent` 0.87.1 declarations, loader, and runtime.
- `session_start` creates an Idle record. `agent_start` sets Working.
  `agent_settled` sets Idle after automatic retries, compaction, and queued
  continuations finish. `agent_end` alone does not change activity.
- `session_before_compact` keeps the Mac awake for manual or automatic
  compaction. `session_compact` and `session_compact_failed` restore the
  underlying run state, including cancellation.
- `ui_prompt_start` sets Idle. `ui_prompt_end` resumes Working only if a run
  or compaction is still active; opening an idle dialog cannot create work.
  This covers Pi's blocking extension UI, not arbitrary terminal input or
  external third-party dialogs. Prompt titles and contents are not forwarded.
- `session_shutdown` removes that lifetime's record. A random lifetime suffix
  keeps separate Pi processes using the same transcript independent, and
  prevents old shutdown events from removing a reloaded session.
- Only session identity, cwd, and lifecycle event names reach the helper.
  Writes are serialized because Pi dispatches UI notifications asynchronously.
  Missing, failing, or hung helpers are ignored, with a one-second timeout per
  event. No shell is involved in launching the helper.
- Install, repair, and removal require the exact first-line ownership marker
  `// __letitbrew_pi_extension`. Settings and other extensions are untouched.
  Use `/reload` or restart Pi after connecting or refreshing the extension.
- `--no-extensions` disables this integration. Remote agents, custom SDK hosts
  that omit extension lifecycle events, and activity such as standalone tree
  summaries are not claimed. Forced termination cannot emit shutdown; the
  existing stale-session policy applies.
