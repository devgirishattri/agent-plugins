---
description: Assign a task to an executor pane and dispatch via session-chat
argument-hint: <pane> <id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Parse `$ARGUMENTS` as: first word = pane, second = task id, then optional flags, rest = prompt. Put flags before the prompt text.

A task with a verification contract (see the `task-contract` skill) accepts only `<pane> <id> <prompt>`. Its options must already be task metadata. `--force` never bypasses the contract or an unadmitted contracted dependency.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. `SESSION_CONTEXT_HOME` must also be present when you use `--context NAME`. `--context auto` does not need it. Each required variable is inherited when the agent process started. The pane/session launcher sets it. Never export or derive it here.

Run the helper as exactly one Bash segment. Use no `export` beforehand and no `env` or variable-assignment prefix. Chain, pipe, redirect, or substitute no other command around it:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-assign.sh" "<pane>" "<id>" [flags] "<prompt>"
```

If the script reports that a required variable is not set, stop. Stop also if your inherited values differ from the shared homes your panes were launched with. Ask the user to relaunch this pane/session with the correct environment. Do not derive another ledger or context store.

Flags:
- `--eta MINUTES` — expected completion window. It stores `eta_at` as ISO-8601 in `AGENT_PLUGINS_TIME_ZONE` (default `Asia/Kolkata`, `+05:30`). Tasks past their ETA show an `OVERDUE` flag in `/task-status` and `/task-board`.
- `--stage NAME` — set or overwrite the task's stage label. Suggested labels: `plan`, `dispatch`, `execute`, `audit`, `push`.
- `--context NAME` — attach a knowledge context snapshot (`$SESSION_CONTEXT_HOME/NAME.md`). `NAME` must be canonical `snake_case` (`^[a-z0-9]+(_[a-z0-9]+)*$`), which is the knowledge context store's own contract. Hyphens, uppercase, leading or trailing underscores, and doubled underscores are invalid. The script rejects a non-canonical name before any side effect. It errors if the snapshot is missing. The generated prompt tells the executor to run `/knowledge:context-load NAME` first, with the absolute context home embedded as provenance. The script records `meta.context` and `meta.context_home` on the task. This is the only form that needs `SESSION_CONTEXT_HOME`.
- `--context auto` — generate a **scheduler-owned** handoff and attach it. The handoff derives from the approved prompt and ledger state. It does not summarize the live session. The script writes it to `handoffs/<task-id>/<nonce>.md` under the shared scheduler home, with mode 0600. The nonce is 32 lowercase hex digits from OS randomness, never the task id or a timestamp. The file is never overwritten: every assignment adds a new file. This form does not touch the knowledge context store and does not need `SESSION_CONTEXT_HOME`. The packet carries the absolute handoff path under a `## Handoff` heading ("read it first"). The ledger records `meta.handoff_file` and `meta.handoff_home` and clears any `meta.context`. The script removes the handoff automatically if the dispatch rolls back. `/tasks-clean` sweeps it together with the task.
- A reassignment with neither form clears all four attachment keys (`meta.context`, `meta.context_home`, `meta.handoff_file`, `meta.handoff_home`). Earlier handoff files stay on disk until `/tasks-clean`.
- `--reviewer PANE` — record a reviewer pane as `.reviewer` on the task. When the executor runs `/task-review`, the audit request is auto-dispatched to this pane. The dispatch is durable. A busy reviewer recovers it on its next turn.
- `--workflow ID` — group this assignment under a workflow id (`meta.workflow_id`). List the group with `/task-status --workflow ID`.
- `--force` — bypass the status-transition check and the unmet-dependency gate. The script records "forced" in history.

Behavior notes:
- The script refuses assignment if any `depends_on` task is not `done`. The error names the unmet dependencies. Complete them, or use `--force`.
- If the script reports that session-chat dispatch failed, the ledger was NOT updated. The script rolled back the prompt file: it deleted a new file and restored a reassignment overwrite. This happens only on a **hard failure**. Examples: no `/whoami`, an unknown or ambiguous target, a durable-queue failure, or unavailable or incompatible session-chat. A **busy** recipient is *not* a failure. The dispatch is durably queued and the ledger still flips to `assigned`. Do not treat busy as a rollback cause. On a hard failure, fix the cause and retry. Remind the user that the executor pane needs `SESSION_CHAT_INCOMING_MODE=auto` (or `assist`) before it can act on the task.
- The first successful assignment stamps `started_at` on the task.
- Report the task state (`assigned`) and the dispatch delivery (Dispatched, Queued, or failed) as separate facts. Delivery alone is not evidence that the executor has acted. Report the executor's action as unverified unless separate evidence from the executor exists. Valid evidence is a correlated reply from the executor pane, a receipt the executor authored, or a ledger transition the executor made (such as `/task-review`, `/task-done`, or `/task-block`).
- The post-dispatch ledger update (metadata and status flip) is one mutation under the per-task lock `locks/<id>.lock/`. A concurrent `/task-done` or `/task-block` on the same task cannot lose an update. The lock is never held across transport. Known limitation: two *simultaneous reassignments of the same task* still race on the prompt file. Run those reassignments one at a time.
- The dispatched prompt always embeds the **absolute** shared ledger home as provenance. The executor verifies that its inherited `SESSION_SCHEDULER_HOME` matches this ledger. With `--context NAME` only, the prompt also embeds the context home. The executor then also verifies that its inherited `SESSION_CONTEXT_HOME` matches. `--context auto` never requires, reads, or resolves `SESSION_CONTEXT_HOME`. If a checked variable is absent or differs, the executor stops and requests a relaunch. The script also records the absolute home as `meta.scheduler_home`.
- The script refuses dispatch if the installed session-chat is below the required floor (durable inbox). Update session-chat, or override with `SESSION_SCHEDULER_SKIP_VERSION_CHECK=1`.
- Transport and escalation: dispatch itself is nested session-chat/tmux transport. If the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt. The command stays one literal Bash segment. Never work around the sandbox with `bash -c`, wrappers, `env`, assignment prefixes, exports, pipelines, chaining, redirection, substitution, or broad provider-home access. Escalation is transport access, not authority. Role, recipient, argument, confirmation, and lifecycle policies remain authoritative. On a hard dispatch failure the rollback above applies. Fix the cause and re-run. Never use --force to repair transport.
