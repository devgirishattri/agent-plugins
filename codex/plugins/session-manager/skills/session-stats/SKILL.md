---
name: session-stats
description: "Show read-only analytics over local Codex session data: per-project session counts, sizes, and last activity, plus totals and the largest sessions. Use when the user asks how much session data exists or which projects/sessions are biggest."
---

# Session Stats

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.5.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

Run one of (the optional argument is a substring filter limiting output to matching projects, e.g. `ProjectA`):

```bash
bash "$PLUGIN_ROOT/scripts/session-stats.sh"
bash "$PLUGIN_ROOT/scripts/session-stats.sh" "<project-filter>"
```

The output has three sections; present them as:

1. Per-project rows (already sorted by last active):

   ```text
   | Project | Sessions | Size | Last Active |
   ```

2. The `TOTALS` line as one summary sentence (projects, sessions, total size).

3. The `TOP 5 LARGEST SESSIONS` section:

   ```text
   | Size | Project | Name |
   ```

The command is read-only. Projects are grouped by the session `cwd` recorded in each session file, and names come from the Codex thread title (falling back to the first user message). Suggest `$session-manager:session-list` to inspect a project and `$session-manager:session-delete` to clean up large sessions.
