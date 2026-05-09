---
description: Inspect session-scheduler setup and session-chat dependency
argument-hint: ""
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-scheduler/0.1.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-scheduler"
   ```

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/scheduler-doctor.sh"
   ```

3. Report scheduler directories, current pane name, session-chat root/version, and incoming-mode guidance.
