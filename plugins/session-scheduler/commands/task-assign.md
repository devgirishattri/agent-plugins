---
description: Assign a task to an executor pane and dispatch via session-chat
argument-hint: <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate. Parse `$ARGUMENTS` as: first word = pane, second = task id, then optional flags, rest = prompt. Flags must come before the prompt text.

`SESSION_SCHEDULER_HOME` (and `SESSION_CONTEXT_HOME` when using `--context`) must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets them — never export or derive them here). Run the helper as exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-assign.sh" "<pane>" "<id>" [flags] "<prompt>"
```

If the script reports either variable is not set — or your inherited values differ from the shared homes your panes were launched with — stop and request that this pane/session be relaunched with the correct environment instead of deriving another ledger or context store.

Flags:
- `--eta MINUTES` — expected completion window; stores `eta_at` (ISO-8601 UTC). Tasks past their ETA show an `OVERDUE` flag in `/task-status` and `/task-board`.
- `--stage NAME` — set/overwrite the task's stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
- `--context NAME` — attach a session-context snapshot (`$SESSION_CONTEXT_HOME/NAME.md`). Errors if the snapshot is missing. The generated prompt tells the executor to run `/session-context:context-load NAME` first (with the absolute context home embedded as provenance), and `meta.context` is recorded on the task.
- `--context auto` — instead of requiring a pre-existing snapshot, generate a private, **immutable** handoff (`auto-<id>-<random>.md`, chmod 400) derived from the approved prompt + ledger state, attach it, and record `meta.context = auto-<id>-<random>` (the exact name is printed in the command output). It is removed automatically if the dispatch rolls back. No live-session summarization — safe to generate from the assignment itself.
- `--reviewer PANE` — record a reviewer pane. When the executor runs `/task-review`, the audit request is auto-dispatched to this pane (durable; recovered on their next turn if busy). Recorded as `.reviewer` on the task.
- `--workflow ID` — group this assignment under a workflow id (`meta.workflow_id`); list the group with `/task-status --workflow ID`.
- `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).

Behavior notes:
- Assignment is refused if any `depends_on` task is not `done` (the error names the unmet deps) — complete them or use `--force`.
- If the script reports session-chat dispatch failed, the ledger was NOT updated and the prompt file was rolled back (deleted if new, restored if it was a reassignment overwrite). This happens only on a **hard failure** (no /whoami, unknown/ambiguous target). A **busy** recipient is *not* a failure — the dispatch is durably queued and the ledger still flips to `assigned` — so do not treat busy as a rollback cause. Fix the hard cause and retry. Remind the user that the executor pane needs `SESSION_CHAT_INCOMING_MODE=auto` (or `assist`) for the task to actually be acted on.
- First successful assignment stamps `started_at` on the task.
- The dispatched prompt embeds the **absolute** shared ledger home (and context home, with `--context`) as provenance so the executor can verify its inherited `SESSION_SCHEDULER_HOME`/`SESSION_CONTEXT_HOME` match this ledger — and stop and request a relaunch if they are absent or differ. The absolute home is also recorded as `meta.scheduler_home`.
- Dispatch is refused if the installed session-chat is below the required floor (durable inbox); update session-chat or override with `SESSION_SCHEDULER_SKIP_VERSION_CHECK=1`.
- Transport and escalation: dispatch itself is nested session-chat/tmux transport. If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt — the command stays one literal Bash segment, and never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority: role, recipient, argument, confirmation, and lifecycle policies remain authoritative. On a hard dispatch failure the rollback above applies — fix the cause and re-run; never use --force to repair transport.
