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
4. Write a summary under 150 lines, including only the relevant sections from:

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

5. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.

6. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Save the snapshot by invoking the helper as
   one literal Bash segment, with no `export` beforehand, no `env` or
   variable-assignment prefix, and no other command chained, piped, redirected,
   or substituted around it:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
   ```

   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store.

   If a snapshot with the same name already exists, the previous version is archived automatically under `SESSION_CONTEXT_HOME/.history/` (the 10 most recent versions are kept). Compare versions later with `$session-context:context-diff <snapshot-name>`.

7. Report: `Session context saved as '<snapshot-name>'. Share with $session-context:context-share <session> <snapshot-name> or load later with $session-context:context-load <snapshot-name>.` If a previous version was archived, mention `$session-context:context-diff <snapshot-name>` to see what changed.
