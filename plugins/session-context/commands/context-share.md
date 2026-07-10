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
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/share-context.sh "<session-name>" "<snapshot-name>"
   ```

3. Relay the script's output as-is — it reports the store path and which transport was used (session-chat's durable inbox when installed, otherwise the builtin fallback). The recipient can load it with `/context-load <snapshot-name>` **only if they share the same store / repo** (sharing notifies; it does not copy the file).
4. If the snapshot doesn't exist, suggest running `/context-generate` first.
