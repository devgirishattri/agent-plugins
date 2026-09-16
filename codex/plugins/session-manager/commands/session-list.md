---
description: List Codex sessions for the current project, or all projects
argument-hint: "[project-path|all]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-sessions.sh" "$ARGUMENTS"
   ```

3. Present the tab-separated output as a clean markdown table:

   ```text
   | Thread | Session ID | Project | Size | Last Modified |
   ```

Rules:
- Sort by Last Modified, most recent first. The script output is already sorted.
- With no argument, list the current project; with a project path, list that exact project; with `all`, list every project.
- Show full Session IDs so users can copy them for `$session-manager:session-delete`.
- Show the latest session name from `~/.codex/session_index.jsonl`.
- If a session has no indexed name, show `(untitled)`; do not substitute its description or first user message.
- Show the total count of sessions at the bottom.
- If the output is empty or says `No sessions found`, report that no sessions were found.
- Mention that `$session-manager:session-list all` shows sessions across all projects.
- Suggest `$session-manager:session-search <query>` to filter results.
