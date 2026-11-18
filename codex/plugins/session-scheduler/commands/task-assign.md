---
description: Assign a scheduler task to a named pane
argument-hint: <pane-name> <task-id> [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] <prompt>
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. Parse `$ARGUMENTS`: first word is target pane, second word is task id, then optional flags, everything after is the prompt. Flags must come before the prompt.
3. `SESSION_SCHEDULER_HOME` (and `SESSION_CONTEXT_HOME` only for explicit `--context NAME`)
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
   dispatch. An assignment without a verification contract writes the transition after transport. In Codex, request scoped
   escalation/approval for the exact installed helper on the first attempt
   whenever it may dispatch. Invoke it as one literal Bash segment with raw
   token zero still `bash`; never use `bash -c`, a wrapper, `env`, an assignment
   prefix, an export, a pipeline, chaining, redirection, substitution, or broad
   provider-home access to bypass the sandbox. Escalation grants transport
   access only: the recorded role and recipient, exact arguments, confirmation
   requirements, and lifecycle rules remain authoritative.
   Never use --force to repair transport.

   A contracted assignment accepts only the pane, task ID and one prompt. It reserves a generation before dispatch. A session-chat status 4 warning counts as delivery. Press Enter once in the named pane. If transport reports an uncertain outcome, inspect the task and follow the assigner's reconciliation procedure before reassigning. Steps 4–7 describe tasks without a verification contract. [Task contracts](../skills/task-contract/SKILL.md)

4. Flags:
   - `--eta MINUTES` — stores `eta_at` as ISO-8601 in `AGENT_PLUGINS_TIME_ZONE` (default `Asia/Kolkata`, `+05:30`); tasks past it are flagged `OVERDUE` in `task-status`/`task-board`.
   - `--stage NAME` — set/overwrite the task's stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
   - `--context NAME` — attach an existing canonical knowledge snapshot (`^[a-z0-9]+(_[a-z0-9]+)*$`); record `meta.context` and `meta.context_home`, clearing prior handoff keys. The packet retains both context-load commands.
   - `--context auto` — write `$SESSION_SCHEDULER_HOME/handoffs/<task-id>/<nonce>.md`, where the nonce is exactly 32 lowercase hex characters from OS randomness. Each file is never overwritten; an existing path is refused. Directories use 0700 and files use 0600, with symlink and ownership checks. The handoff contains the approved prompt and ledger state, with no live-session summarization. Record its absolute path in `meta.handoff_file` and its absolute home in `meta.handoff_home`, clearing prior context keys. The packet tells the recipient to read that path directly; it is not a knowledge snapshot. Auto does not require, read, create, or resolve `SESSION_CONTEXT_HOME`.
   - `--reviewer PANE` — set or override automatic independent-review routing.
   - `--workflow ID` — set or override the workflow group; `--workflow-id` is an alias.
   - `--force` can override an ordinary status transition or an unmet ordinary prerequisite. Overriding an illegal transition records `forced` in history. A contracted prerequisite still requires admission.
5. An ordinary prerequisite normally needs status `done`. A contracted prerequisite always needs valid admission, including when the dependent task uses `--force`. An ordinary illegal status transition is also refused unless explicitly forced.
6. On hard dispatch failure the ledger is NOT updated; the prompt and automatic handoff file are rolled back, along with its per-task handoff directory if empty. Fix the hard transport cause and retry the same legal assignment. A busy target is queued durably. If the chat transport returns 4, `task-assign` records the assignment, reports `Dispatch: unsubmitted`, and returns 0. Its input is staged and a durable copy is queued. Press Enter once in the named recipient pane. Successful dispatch records the absolute shared homes for the recipient.
7. If dispatch succeeds, report the task id and assignee, plus `handoff: <absolute path>` for auto or `context: NAME` for an explicit snapshot. First successful assignment stamps `started_at`. Assignment metadata and the status transition are persisted together under the per-task lock. Value-taking flags require a value.
8. If the target pane is missing or duplicated, suggest checking `$session-chat:panes` and `$session-chat:whoami`.
9. Mention that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.

For a task without a verification contract, reassignment without `--context` clears all four attachment keys: `meta.context`, `meta.context_home`, `meta.handoff_file`, and `meta.handoff_home`. Locks cover ledger read-modify-write operations only, not transport; simultaneous assignments to the same task can race prompt writes and rollback, so coordinate assignments to each task serially.
