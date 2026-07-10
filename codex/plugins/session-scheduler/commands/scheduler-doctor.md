---
description: Inspect session-scheduler setup and session-chat dependency
argument-hint: ""
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/scheduler-doctor.sh"
   ```

3. Report scheduler/context directories, current pane, enforced session-chat version, date math, workspace-root consistency, and ledger provenance. A workspace-home warning means a child checkout may be writing to a private ledger and must be fixed before dispatch.
