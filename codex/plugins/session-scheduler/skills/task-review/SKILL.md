---
name: task-review
description: "Move an assigned scheduler task to review with a note (e.g. a commit SHA) and notify the assigner."
---

# Task Review

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.4.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run (the note is required — typically a commit SHA or a one-line summary of what to audit):

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/task-review.sh" "<task-id>" [--force] "<note>"
```

The executor (or orchestrator) runs this when work is ready for audit. Legal only from `assigned`. The reviewer then approves with `$session-scheduler:task-done` or rejects with `$session-scheduler:task-block`. Report that the task was moved to review.
