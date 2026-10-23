# Agent Hook Contracts

## Product boundary

Let It Brew observes local lifecycle hooks only. It does not enumerate agent
processes, inspect CPU use, search for installed executables, parse conversations,
or read Claude/Codex/OpenCode/Copilot/Pi prompt and response content. Each hook
command reads only its own parent chain to record the agent's process ID, which
the menu uses to bring the agent's app forward; it affects the hold only by
naming the app whose input can answer a Claude or Copilot approval.

Every adapter reduces to Working, Waiting, and Idle. A Waiting session releases
the hold. Waits whose answer sends a hook resume through that hook; Claude and
Copilot approvals, which send none, hold again once a local key press or click
reaches the session's own app; see [ARCHITECTURE.md](ARCHITECTURE.md) for that
rule.

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
- `SessionStart` is Idle only for source `startup`, `resume`, or `clear`; any
  other or missing source preserves the prior state.
- `SessionStart` source `compact`, `PreCompact`, and `PostCompact` with
  `trigger: auto` preserve the prior state. Compaction can run at an idle prompt
  (`/compact`, or idle auto-compaction with `trigger: auto`) and an aborted
  compact emits `PreCompact` alone, with no later `Stop`; `trigger: auto` does
  not distinguish idle from in-turn compaction. `PostCompact` with
  `trigger: manual` is Idle, because a manual compact completes only at the
  idle prompt, unless the parent is Working only because its `Stop` reported
  background tasks. On Stop, each `background_tasks` entry contributes only
  its `id`, `type`, and `status`; task prose, commands, and output are
  discarded. Entries whose status is `idle`, `done`, `success`, `succeeded`,
  `complete`, `completed`, `finished`, `failed`, `error`, `terminated`,
  `exited`, `aborted`, `expired`, `skipped`, `crashed`, `killed`, `cancelled`,
  `canceled`, or `timed_out` are finished. Any other, missing, or unrecognized
  status may still be working. A working entry of type `shell` or `monitor`
  is shell-only work: Stop stays Working with detail `background-shell`, and
  the app bounds that hold to `Settings.backgroundShellHoldLimit` (one hour)
  measured from the record's latest edge, because a shell the agent forgot
  cannot be told from a long build by status alone. A working entry of any
  other type, including `subagent`, `teammate`, `workflow`, and a missing or
  future type, is agent work: Stop stays Working with detail
  `background-agent` and is not bounded. An empty array, or only finished
  entries, makes Stop Idle. An absent array keeps Stop Idle without proving
  anything about children. `session_crons` are not treated as current work.
  A shell a subagent started belongs to the session and survives that
  subagent's `SubagentStop`; observed on Claude Code 2.1.x.
- A Claude `Stop` whose `background_tasks` array identifies every entry is a
  complete inventory of the session's in-flight tasks, and a running subagent
  is listed under its own `agent_id`. Such a Stop deletes child records the
  inventory does not list as working, because their `SubagentStop` will never
  come (observed for handed-back and killed agents). An absent array, or any
  entry without an `id`, prunes nothing. Only the Stop that became the
  parent's latest edge prunes, and a child heard after it is kept.
- `SubagentStop` removes its child record. Its snapshot is scoped to the
  parent and, for a backgrounded subagent, still lists the stopping child as
  running; the child's own entry is ignored before judging the parent. With
  no remaining work it makes a parent still Working only on background work
  Idle; with shell-only work left it moves that parent to the bounded
  `background-shell` hold, keeping an earlier shell-only start; with agent
  work left it changes nothing. An absent/null snapshot cannot prove
  completion. A newer foreground event prevents this parent reconciliation.
- Parent `SessionEnd` removes the parent's children as well. A bounded family
  lock serializes child updates with termination; terminal markers prevent late
  hooks from recreating that family until `SessionStart` or `UserPromptSubmit`.
  Older observations cannot close a newer parent or child. Other sessions and
  agents are unaffected. Readers exclude children of an ended parent even if
  cleanup was interrupted; a precise reopen timestamp keeps leftovers from a
  previous run excluded after resume. Missing/unreadable parent state does not
  itself suppress a child's work.
- `PermissionRequest` preserves prior state: Claude runs it before another
  `PermissionRequest` hook or auto mode decides, so it does not prove a prompt
  is shown. A `permission_prompt` `Notification` is Waiting (approval): Claude
  sends it only after its prompt has waited on screen for about six seconds,
  and not when a hook answers sooner. `PreToolUse` for `AskUserQuestion` is
  Waiting (question); its `PostToolUse` returns the session to Working. Other
  notification types, including `elicitation_dialog`, preserve prior state.
  API-error turns use `StopFailure`;
  user-interrupted turns have no immediate documented terminal hook. Observed
  on Claude Code 2.1.304: Esc while a tool runs, while text streams, or while
  text streams after a completed tool emits no `Stop`, `StopFailure`,
  `PostToolUseFailure`, or `idle_prompt` `Notification` (none within 150s). The
  turn stays Working until the next prompt's `Stop`, a manual `/compact`,
  `SessionEnd`, Stop Tracking, or the 12-hour expiry.
  Permission approval has no matching immediate hook to resume a hold before
  the tool executes. A Waiting approval therefore releases the hold only until
  a local key press or click in the session's own app follows the prompt;
  after that it holds as Working until the next hook. An approval from another device with
  the lid open has no local input and can still sleep mid-tool.
  Without a later authoritative event, interrupted turns and stopped parents
  with unreported agent-class background completion can remain Working until
  the existing 12-hour expiry. Silence alone does not prove work ended. A
  shell or monitor still reported as running holds for the bounded limit
  above. A Working or Waiting session whose recorded agent process has exited
  neither shows nor holds; records without a process ID keep the hook-only
  behavior.
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
  `SubagentStop`→SubagentStop, `Stop`→Stop, `SessionEnd`→SessionEnd,
  `Interrupt`→Interrupt.
- `session_id` is the parent session ID for subagent hooks. Combine it with
  `agent_id` for an independent child record.
- `SessionStart` source `compact`, `PreCompact`, and `PostCompact` preserve
  the prior state. `PermissionRequest` preserves prior state: Codex runs it
  before its own auto-reviewer (`approvals_reviewer = auto_review`) and the
  person decide, and hooks cannot tell which one answered, so an approval
  keeps the Mac awake as before. `PreToolUse` for `request_user_input`
  (Codex 0.145+) is Waiting (question); its `PostToolUse` returns to Working.
- `Interrupt` (Codex 0.150+) is Idle; it is the only hook an Esc-cancelled turn
  fires. Codex caps its timeout at 3 seconds, so it is installed with 3; every
  other event uses 5. Older Codex ignores the key, so runtime trust
  verification accepts its absence but requires trust when Codex reports it.
- Parent `SessionEnd` removes the parent's children, under the same family lock
  and terminal markers as Claude; readers likewise exclude children of an ended
  parent if cleanup was interrupted. Codex can omit a child's `SubagentStop`, so a
  parent `Stop` or `Interrupt` also removes children that sent no hook since the parent's
  latest `UserPromptSubmit`, recorded at its exact time. The parent keeps that
  cutoff, and readers and later child hooks honor it like a terminal marker. A
  child heard during that turn is kept: hooks cannot tell a stuck child from
  one still running.
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
  PermissionRequest and Waiting (approval). `permission.replied` and
  `permission.v2.replied` return the session to Working for every reply.
- `question.asked` maps to Waiting (question). `question.replied` and
  `question.rejected` return the session to Working.
- OpenCode v2 beta is not claimed by this release.

## GitHub Copilot CLI

- Config: `~/.copilot/hooks/letitbrew.json`, relocated by `COPILOT_HOME`.
- Sources: https://docs.github.com/en/copilot/reference/hooks-reference and
  https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-hooks
- Use PascalCase compatibility events for snake_case payloads: SessionStart,
  UserPromptSubmit, PermissionRequest, PreToolUse, PostToolUse,
  PostToolUseFailure, Notification, ErrorOccurred, Stop, and SessionEnd.
  PostToolUseFailure is installed from v1.0.0.
- PermissionRequest keeps the prior state: Copilot runs it before allow rules,
  session approvals, and auto-allow decide, so it does not prove a person is
  being asked. It becomes Waiting (question) only for the question tool.
  PreToolUse becomes Waiting (question) for `ask_user`, `ask_user_question`,
  and `AskUserQuestion`; other tools become Working. PostToolUse and
  PostToolUseFailure return a completed, failed, or cancelled question to
  Working. Notification becomes Waiting (approval) for `permission_prompt` and
  `elicitation_dialog`. Copilot fires no hook when an approval is granted, so
  a local key press or click in the session's own app after the wait holds it
  as Working until the next
  hook.
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
- `ui_prompt_start` sets Waiting (question) only while a run or compaction is
  active; a dialog at the idle prompt is ignored. Nested dialogs are one wait,
  and `ui_prompt_end` for the outermost resumes Working. `agent_start` ends
  any wait, because a run cannot begin under a dialog.
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
