---
name: task-assign
description: "Assign an existing scheduler task to a named pane through session-chat, with optional ETA, stage, and context attachment."
---

# Task Assign

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.2.1}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run (flags must come before the prompt text):

```bash
bash "$PLUGIN_ROOT/scripts/task-assign.sh" "<pane-name>" "<task-id>" [--eta MINUTES] [--stage NAME] [--context NAME] [--force] "<prompt>"
```

- `--eta MINUTES` — stores `eta_at`; overdue tasks are flagged `OVERDUE` in status/board views.
- `--stage NAME` — set/overwrite the stage label.
- `--context NAME` — attach the session-context snapshot at `<git-root>/tmp/contexts/NAME.md` (errors if missing); the prompt tells the executor to `$session-context:context-load NAME` first.
- `--force` — bypass the status-transition check and unmet-dependency gate (records "forced" in history).

Assignment is refused while any `depends_on` task is not `done`. On dispatch failure the ledger is not updated and the prompt file is rolled back. Report success or the precise session-chat error. Remind the user that executor panes need `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to act on assigned dispatches.
