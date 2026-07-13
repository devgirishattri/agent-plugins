---
name: task-assign
description: "Assign a scheduler task with ETA, workflow, reviewer routing, and existing or automatic context attachment."
---

# Task Assign

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` (and `SESSION_CONTEXT_HOME` when using `--context`)
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

- `--eta MINUTES` — stores `eta_at`; overdue tasks are flagged `OVERDUE` in status/board views.
- `--stage NAME` — set/overwrite the stage label.
- `--context NAME` — attach an existing snapshot under `SESSION_CONTEXT_HOME`.
- `--context auto` — create a private immutable task handoff from the approved prompt and current ledger state, then attach it.
- `--reviewer PANE` — set or override the independent reviewer route.
- `--workflow ID` — set or override the workflow group; `--workflow-id` is an alias.
- `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).

Assignment is refused while any `depends_on` task is not `done`. On dispatch failure the ledger is not updated, the prompt is rolled back, and an auto-generated context is removed. Report success or the precise session-chat error. The dispatch records the absolute shared scheduler/context homes; the recipient must preserve them for every status command. Remind the user that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist`.
