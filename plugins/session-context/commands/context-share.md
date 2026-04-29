---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
allowed-tools: Bash(bash:*)
---

## Instructions

1. Parse $ARGUMENTS: first word is the target session, second word (optional) is the snapshot name.
   - If no snapshot name given, derive from current directory name.

2. Run the share script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/share-context.sh "<session-name>" "<snapshot-name>"
   ```

3. Report: "Shared session context '<snapshot-name>' with <session>. They can load it with `/context-load <snapshot-name>`."
4. If the snapshot doesn't exist, suggest running `/context-generate` first.
