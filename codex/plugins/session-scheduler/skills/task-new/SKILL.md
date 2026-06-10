---
name: task-new
description: "Create a session-scheduler task record, optionally with a stage label and dependencies."
---

# Task New

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/task-new.sh" <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2]
```

- `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
- `--depends-on id1,id2` — comma-separated existing task ids; assignment is gated until every dependency is `done`.

Return the created task id and name.
