---
description: Generate a session context summary for handoff to another session
argument-hint: [snapshot-name]
---

## Instructions

Generate a concise summary of what this session has been working on.

1. Determine the snapshot name from `$ARGUMENTS`; if empty, derive it from the current directory name.
2. Gather session context from relevant local sources:

   ```bash
   git diff --stat HEAD
   git log --oneline -10
   git diff --name-only HEAD~5..HEAD
   ```

3. Check for `docs/TODO.md` and `docs/ISSUES.md` if they exist.
4. Write a summary under 150 lines with these sections:

   ```text
   # Session Context: <name>
   Generated: YYYY-MM-DD HH:MM
   Project: <current directory>

   ## What Was Done
   ## Files Changed
   ## Key Decisions
   ## Open Issues
   ## Where I Left Off
   ## Notes for Next Session
   ```

5. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.1.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
   ```

6. Save the snapshot:

   ```bash
   bash "$PLUGIN_ROOT/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
   ```

7. Report: `Session context saved as '<snapshot-name>'. Share with /context-share <session> <snapshot-name> or load later with /context-load <snapshot-name>.`
