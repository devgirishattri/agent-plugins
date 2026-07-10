---
description: Generate a session context summary for handoff to another session
argument-hint: "[snapshot-name]"
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

5. Resolve `PLUGIN_ROOT` from this command resource's absolute source path by going up one directory from `<plugin-root>/commands`. Never derive it from the project working directory or embed a cache version.

6. Save the snapshot:

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
   ```

   If a snapshot with the same name already exists, the previous version is archived automatically to `tmp/contexts/.history/` (the 10 most recent versions are kept). Compare versions later with `$session-context:context-diff <snapshot-name>`.

7. Report: `Session context saved as '<snapshot-name>'. Share with $session-context:context-share <session> <snapshot-name> or load later with $session-context:context-load <snapshot-name>.` If a previous version was archived, mention `$session-context:context-diff <snapshot-name>` to see what changed.
