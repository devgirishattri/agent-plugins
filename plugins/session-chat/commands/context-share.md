---
description: Share a project context snapshot with another named session
argument-hint: <session-name> [project-name]
allowed-tools: Bash(bash:*)
---

## Instructions

1. Parse $ARGUMENTS: first word is the target session, second word (optional) is the project name.
   - If no project name given, derive from current directory name.

2. Run the share script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/share-context.sh "<project-name>" "<session-name>"
   ```

3. Report what was shared and how the target can load it.
4. If the snapshot doesn't exist, suggest running `/context-generate` first.
