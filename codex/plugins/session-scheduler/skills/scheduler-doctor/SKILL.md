---
name: scheduler-doctor
description: "Inspect scheduler dependencies and detect child-vs-workspace ledger/context home drift."
---

# Scheduler Doctor

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Run exactly one Bash segment, with no `export`
beforehand, no `env` or variable-assignment prefix, and no other command
chained, piped, redirected, or substituted around it:

```bash
bash "<PLUGIN_ROOT>/scripts/scheduler-doctor.sh"
```

If the script reports `SESSION_SCHEDULER_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another ledger.

Report scheduler/context directories, pane name, enforced session-chat version,
date math, workspace-root consistency, and ledger provenance. Treat any
workspace-home warning as a routing defect to fix before assigning work.
