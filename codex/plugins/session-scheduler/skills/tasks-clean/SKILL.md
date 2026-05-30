---
name: tasks-clean
description: "Dry-run or delete old scheduler task records."
---

# Tasks Clean

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/tasks-clean.sh" <args>
```

Without `--apply`, this is a dry run. With `--apply`, report the deleted count.
