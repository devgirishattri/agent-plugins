---
name: workspace-doctor
description: "Dependency/config health check for the session-workspace engine. Use when the user asks to check workspace health, diagnose session-workspace, or verify config/dependencies."
---

# workspace-doctor

When this skill is invoked, do not add a preamble or narrate the plan. Run
the relevant script directly, then return only the formatted result.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it
is the directory two levels above this `SKILL.md`. Use that absolute path;
never infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-doctor.sh" $ARGUMENTS
```

Real flags:
- `--config PATH`: use a specific workspace config instead of discovery.
- `--json`: emit the health report as JSON.

`workspace-doctor` is strictly read-only: it diagnoses and never repairs,
creates, starts, stops, attaches, or kills anything. It does not execute
config-supplied runtime programs; runtime checks use `command -v` only.

It checks required tooling (tmux >= 3.2, jq, git), config discovery + full
validation, plugin dependency versions and cache-vs-source drift, pane cwds,
secret-file metadata gates, state-dir availability, runtime availability,
coordination-base drift, and session-chat helper resolution.

Each check reports `OK`, `INFO`, `WARN`, or `ERROR` with remediation text; the
script exits non-zero only when at least one check is `ERROR`. Relay the
per-check statuses and remediation lines. Do not run suggested fixes yourself
unless the user asks.
