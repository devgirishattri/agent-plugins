---
description: Show read-only analytics for local Codex session data (per-project counts, sizes, last activity)
argument-hint: "[project-filter]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

2. Run (the optional argument is a substring filter limiting output to matching projects):

   ```bash
   bash "$PLUGIN_ROOT/scripts/session-stats.sh" "$ARGUMENTS"
   ```

3. The output has three sections. Present each one:

   - Per-project rows (tab-separated, already sorted by last active) as a markdown table:

     ```text
     | Project | Sessions | Size | Last Active |
     ```

   - The `TOTALS` line as a single summary sentence: total projects, total sessions, total size.

   - The `TOP 5 LARGEST SESSIONS` section as a markdown table:

     ```text
     | Size | Project | Name |
     ```

Rules:
- This command is read-only — it never modifies session data.
- Projects are grouped by the session `cwd` recorded in each session file.
- If a session has no thread title, it shows as `(untitled)`.
- If `$ARGUMENTS` was given, mention that results are filtered to projects matching it.
- If the output says `No sessions found`, report that and stop.
- Suggest `$session-manager:session-list <project>` to inspect a specific project's sessions and `$session-manager:session-delete <session-id>` to clean up large ones.
