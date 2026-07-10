---
name: task-assign
description: "Assign a scheduler task with ETA, workflow, reviewer routing, and existing or automatic context attachment."
---

# Task Assign

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run (flags must come before the prompt text):

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/task-assign.sh" "<pane-name>" "<task-id>" [--eta MINUTES] [--stage NAME] [--context NAME|auto] [--reviewer PANE] [--workflow ID] [--force] "<prompt>"
```

- `--eta MINUTES` — stores `eta_at`; overdue tasks are flagged `OVERDUE` in status/board views.
- `--stage NAME` — set/overwrite the stage label.
- `--context NAME` — attach an existing snapshot under `SESSION_CONTEXT_HOME`.
- `--context auto` — create a private immutable task handoff from the approved prompt and current ledger state, then attach it.
- `--reviewer PANE` — set or override the independent reviewer route.
- `--workflow ID` — set or override the workflow group; `--workflow-id` is an alias.
- `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).

Assignment is refused while any `depends_on` task is not `done`. On dispatch failure the ledger is not updated, the prompt is rolled back, and an auto-generated context is removed. Report success or the precise session-chat error. The dispatch records the absolute shared scheduler/context homes; the recipient must preserve them for every status command. Remind the user that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist`.
