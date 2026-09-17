---
name: session-list
description: "List local Codex sessions for the current project or all projects. Use when the user asks to list sessions or inspect recent Codex sessions."
---

# Session List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from the selected skill's absolute path: it is the session-manager directory containing `skills/` and `scripts/`. Never hard-code a marketplace cache version.

Run one of:

```bash
bash "$PLUGIN_ROOT/scripts/list-sessions.sh"
bash "$PLUGIN_ROOT/scripts/list-sessions.sh" "<project-path>"
bash "$PLUGIN_ROOT/scripts/list-sessions.sh" all
```

Present tab-separated output as:

```text
| Thread | Session ID | Project | Size | Last Modified |
```

Show full session IDs and a total count. Native metadata supplies the title when
available; the compatibility backend uses the latest indexed name. Missing
names remain `(untitled)`; never substitute a description or first user message.
The helper connects only to an existing local Codex daemon and falls back to
filesystem metadata. Relay backend diagnostics from stderr. `unknown` size
means native history has no known local file size, not zero storage.
For explicit archive requests append `--archived`; for machine-readable requests
append `--json` (includes per-row source and nullable physical bytes). The
launch environment may select `SESSION_MANAGER_BACKEND=auto|native|filesystem`;
do not change it implicitly. Native deletion remains a separate workflow.
