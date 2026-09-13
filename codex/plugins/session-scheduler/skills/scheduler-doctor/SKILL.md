---
name: scheduler-doctor
description: "Inspect scheduler dependencies, ledger provenance, handoffs, and legacy context residue."
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

Report the ledger home and whether it is inside the current git root, handoffs
directory count, pane name, enforced session-chat version, date math, and ledger
provenance. Custom workspace store locations are supported; there is no fixed
`.tmp/scheduler` expected-path comparison.

Report `SESSION_CONTEXT_HOME` as set or unset without creating or resolving it.
Only explicit `--context NAME` needs that variable; auto handoffs use the
scheduler home. Surface any WARN listing legacy `auto_handoff_*.md` context
files and the manual removal command. Diagnostics are read-only and never
delete legacy residue.
