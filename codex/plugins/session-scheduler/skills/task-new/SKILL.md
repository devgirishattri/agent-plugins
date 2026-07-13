---
name: task-new
description: "Create a scheduler task with optional stage, dependencies, reviewer route, and workflow group."
---

# Task New

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment, with no `export`
beforehand, no `env` or variable-assignment prefix, and no other command
chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/task-new.sh" <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2] [--reviewer PANE] [--workflow ID]
```

If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another ledger.

- `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
- `--depends-on id1,id2` — comma-separated existing task ids; assignment is gated until every dependency is `done`.
- `--reviewer PANE` — route `task-review` automatically to this independent reviewer.
- `--workflow ID` — group related tasks; `--workflow-id` is accepted as an alias.

Return the created task id and name.
