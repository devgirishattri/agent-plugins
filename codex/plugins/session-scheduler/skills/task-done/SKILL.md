---
name: task-done
description: "Mark a scheduler task done (records duration) and notify the assigner when possible."
---

# Task Done

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/task-done.sh" "<task-id>" [--force] "<note>"
```

Legal from `assigned` or `review` (review approval); other transitions are rejected unless `--force` (which records "forced" in history). Records `duration_seconds` since first assignment. Report that the task was marked done.
