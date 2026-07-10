---
name: scheduler-doctor
description: "Inspect scheduler dependencies and detect child-vs-workspace ledger/context home drift."
---

# Scheduler Doctor

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/scheduler-doctor.sh"
```

Report scheduler/context directories, pane name, enforced session-chat version,
date math, workspace-root consistency, and ledger provenance. Treat any
workspace-home warning as a routing defect to fix before assigning work.
