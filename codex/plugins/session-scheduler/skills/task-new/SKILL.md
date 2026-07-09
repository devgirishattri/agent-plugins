---
name: task-new
description: "Create a session-scheduler task record, optionally with a stage label and dependencies."
---

# Task New

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-scheduler/0.4.1}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-new.sh" <name> [--meta k=v] [--stage NAME] [--depends-on id1,id2]
```

- `--stage NAME` — optional pipeline stage label (suggested: `plan`, `dispatch`, `execute`, `audit`, `push`).
- `--depends-on id1,id2` — comma-separated existing task ids; assignment is gated until every dependency is `done`.

Return the created task id and name.
