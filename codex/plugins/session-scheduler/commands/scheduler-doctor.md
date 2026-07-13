---
description: Inspect session-scheduler setup and session-chat dependency
argument-hint: ""
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Run exactly one Bash segment, with no
   `export` beforehand, no `env` or variable-assignment prefix, and no other
   command chained, piped, redirected, or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/scheduler-doctor.sh"
   ```

   If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request
   that this pane be relaunched with the correct environment instead of
   deriving another ledger.

3. Report scheduler/context directories, current pane, enforced session-chat version, date math, workspace-root consistency, and ledger provenance. A workspace-home warning means a child checkout may be writing to a private ledger and must be fixed before dispatch.
