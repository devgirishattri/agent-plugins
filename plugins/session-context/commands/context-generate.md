---
description: Generate a session context summary — what you worked on, decisions made, where you left off
argument-hint: [snapshot-name]
allowed-tools: Read, Glob, Grep, Bash(bash:*)
---

## Instructions

Generate a concise summary of what THIS session has been working on — for handing off to another session.

1. **Determine snapshot name**: Use $ARGUMENTS if provided, otherwise derive from the Claude session name or current directory name.

2. **Gather session context** by checking:
   - `git diff --stat HEAD` — files currently modified
   - `git log --oneline -10` — recent commits in this session
   - `git diff --name-only HEAD~5..HEAD` — files changed in last 5 commits
   - Any `docs/TODO.md` or `docs/ISSUES.md` — tracked items
   - Any open problems or blockers encountered during the conversation

3. **Generate the summary** with these sections (include only what's relevant):

   ```
   # Session Context: <name>
   Generated: YYYY-MM-DD HH:MM
   Project: <current directory>

   ## What Was Done
   [Bullet list of completed work — features added, bugs fixed, refactors made]

   ## Files Changed
   [List of files modified/created/deleted with brief description]

   ## Key Decisions
   [Decisions made during the session and WHY — these are the hardest to reconstruct]

   ## Open Issues
   [Problems discovered, unresolved bugs, things that need attention]

   ## Where I Left Off
   [Current state — what's in progress, what the next step should be]

   ## Notes for Next Session
   [Gotchas, context that isn't obvious from the code, warnings]
   ```

4. **Save the snapshot**: Write it to a temp file, then run:
   ```
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/save-context.sh "<snapshot-name>" "<temp-file>"
   ```
   If a snapshot with the same name already exists, the previous version is archived
   automatically to `tmp/contexts/.history/` (the 10 most recent versions are kept).
   Compare versions later with `/context-diff <snapshot-name>`.

5. **Report**: "Session context saved as '<snapshot-name>'. Share with `/context-share <session> <snapshot-name>` or load later with `/context-load <snapshot-name>`." If a previous version was archived, mention `/context-diff <snapshot-name>` to see what changed.

Keep the summary **concise** — under 150 lines. Focus on what another session needs to continue the work, not a transcript of everything that happened.
