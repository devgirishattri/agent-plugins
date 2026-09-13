---
name: task-assign
description: "Assign a scheduler task with ETA, workflow, reviewer routing, and existing or automatic context attachment."
---

# Task Assign

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` (and `SESSION_CONTEXT_HOME` only for explicit `--context NAME`)
must already be present in this pane's environment, inherited when the agent
process started (the pane/session launcher sets them — never export or derive
them here). Run exactly one Bash segment (flags must come before the prompt
text), with no `export` beforehand, no `env` or variable-assignment prefix, and
no other command chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-assign.sh" "<pane-name>" "<task-id>" [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] "<prompt>"
```

If the script reports either variable is not set — or the inherited values
differ from the shared homes the panes were launched with — stop and request a
pane relaunch with the correct environment instead of deriving another ledger
or context store.

## Transport contract

`task-assign` performs nested session-chat/tmux dispatch before it writes the
assignment transition. In Codex, request scoped escalation/approval for the
exact installed helper on the first attempt whenever it may dispatch. Invoke
that helper as one literal Bash segment with raw token zero still `bash`; never
work around the sandbox with `bash -c`, a wrapper, `env`, an assignment prefix,
an export, a pipeline, chaining, redirection, substitution, or broad
provider-home access.

Escalation grants transport access only. The recorded role and recipient, exact
arguments, confirmation requirements, and lifecycle rules remain authoritative;
never use --force to repair transport. On a hard dispatch failure, the ledger
is still not updated, the prompt and automatic handoff file are rolled back,
and the per-task handoff directory is removed if empty. Fix the hard transport
cause and retry the same legal assignment.

- `--eta MINUTES` — stores `eta_at`; overdue tasks are flagged `OVERDUE` in status/board views.
- `--stage NAME` — set/overwrite the stage label.
- `--context NAME` — attach an existing canonical snapshot under `SESSION_CONTEXT_HOME`; names must match `^[a-z0-9]+(_[a-z0-9]+)*$` (lowercase snake_case only).
- `--context auto` — write `$SESSION_SCHEDULER_HOME/handoffs/<task-id>/<nonce>.md` from the approved prompt and current ledger state, with no live-session summarization. The nonce is exactly 32 lowercase hex characters from OS randomness. Each file is never overwritten; an existing path is refused. Directories use 0700 and files use 0600 with symlink and ownership checks. Auto does not require, read, create, or resolve `SESSION_CONTEXT_HOME`. The packet carries the absolute handoff path for direct reading, not knowledge context-load commands.
- `--reviewer PANE` — set or override the independent reviewer route.
- `--workflow ID` — set or override the workflow group; `--workflow-id` is an alias.
- `--force` — bypass the status-transition check and unmet-dependency gate; an illegal-transition override records "forced" in history, while bypassing only the dependency gate does not.

Auto records `meta.handoff_file` and `meta.handoff_home`, clearing prior context keys. Explicit NAME records `meta.context` and `meta.context_home`, clearing prior handoff keys. The command prints `handoff: <absolute path>` for auto and `context: NAME` for explicit context. Assignment metadata and status are persisted together under the per-task lock. Value-taking flags require a value.

Reassignment without `--context` clears all four attachment keys: `meta.context`, `meta.context_home`, `meta.handoff_file`, and `meta.handoff_home`. Locks cover ledger read-modify-write operations only, not transport; simultaneous assignments to the same task can race prompt writes and rollback, so coordinate assignments to each task serially.

Assignment is refused while any `depends_on` task is not `done`. Report success or the precise session-chat error. The dispatch records the absolute shared scheduler home and, for explicit NAME only, context home; the recipient must preserve the relevant inherited environment. Remind the user that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist`.
