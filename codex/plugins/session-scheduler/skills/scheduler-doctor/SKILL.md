---
name: scheduler-doctor
description: "Inspect session-scheduler directories, pane name, and session-chat dependency."
---

# Scheduler Doctor

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/scheduler-doctor.sh"
```

Report scheduler directories, current pane name, session-chat root/version, and incoming-mode guidance.
