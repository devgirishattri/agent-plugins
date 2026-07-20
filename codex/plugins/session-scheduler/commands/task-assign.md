---
description: Assign a scheduler task to a named pane
argument-hint: <pane-name> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. Parse `$ARGUMENTS`: first word is target pane, second word is task id, then optional flags, everything after is the prompt. Flags must come before the prompt.
3. `SESSION_SCHEDULER_HOME` (and `SESSION_CONTEXT_HOME` when using `--context`)
   must already be present in this pane's environment, inherited when the agent
   process started (the pane/session launcher sets them — never export or
   derive them here). Run exactly one Bash segment, with no `export`
   beforehand, no `env` or variable-assignment prefix, and no other command
   chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/task-assign.sh" "<pane-name>" "<task-id>" [flags] "<prompt>"
   ```

   If the script reports either variable is not set — or the inherited values
   differ from the shared homes the panes were launched with — stop and request
   that this pane be relaunched with the correct environment instead of
   deriving another ledger or context store.

   **Transport contract:** `task-assign` performs nested session-chat/tmux
   dispatch before its ledger write. In Codex, request scoped
   escalation/approval for the exact installed helper on the first attempt
   whenever it may dispatch. Invoke it as one literal Bash segment with raw
   token zero still `bash`; never use `bash -c`, a wrapper, `env`, an assignment
   prefix, an export, a pipeline, chaining, redirection, substitution, or broad
   provider-home access to bypass the sandbox. Escalation grants transport
   access only: the recorded role and recipient, exact arguments, confirmation
   requirements, and lifecycle rules remain authoritative.
   Never use --force to repair transport.

4. Flags:
   - `--eta MINUTES` — stores `eta_at` as ISO-8601 in `AGENT_PLUGINS_TIME_ZONE` (default `Asia/Kolkata`, `+05:30`); tasks past it are flagged `OVERDUE` in `task-status`/`task-board`.
   - `--stage NAME` — set/overwrite the task's stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--context NAME|auto` — attach an existing snapshot, or create an immutable task-scoped handoff named `task-<id>-<random>`; the exact generated name is printed.
   - `--reviewer PANE` — set or override automatic independent-review routing.
   - `--workflow ID` — set or override the workflow group; `--workflow-id` is an alias.
   - `--force` — bypass the status-transition check and unmet-dependency gate; an illegal-transition override records "forced" in history, while bypassing only the dependency gate does not.
5. Assignment is refused if any `depends_on` task is not `done` (the error names the unmet deps) — complete them or use `--force`. Illegal status transitions (e.g. assigning a `done` task) are also refused.
6. On hard dispatch failure the ledger is NOT updated; the prompt and any automatic context are rolled back. Fix the hard transport cause and retry the same legal assignment. A busy target is queued durably and still counts as a successful assignment. Successful dispatch records the absolute shared homes for the recipient.
7. If dispatch succeeds, report the task id and assignee. First successful assignment stamps `started_at`.
8. If the target pane is missing or duplicated, suggest checking `$session-chat:panes` and `$session-chat:whoami`.
9. Mention that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
