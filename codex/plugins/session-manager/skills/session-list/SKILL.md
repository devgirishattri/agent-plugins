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
bash "$PLUGIN_ROOT/scripts/list-sessions.sh" all
```

Present tab-separated output as:

```text
| Thread | Session ID | Project | Size | Last Modified |
```

Show full session IDs and a total count. The first column is the Codex thread title from `~/.codex/state_5.sqlite`, falling back to the first user message only when the thread title is unavailable.
