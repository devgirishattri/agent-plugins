---
name: task-block
description: "Mark a scheduler task blocked (or reject a review) and notify the assigner when possible."
---

# Task Block

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-scheduler/0.4.1}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-block.sh" "<task-id>" [--force] "<reason>"
```

Legal from `created`, `assigned`, or `review` (review rejection); other transitions are rejected unless `--force`. Unblock by re-running task-assign (blocked → assigned is legal). Report that the task was marked blocked.
