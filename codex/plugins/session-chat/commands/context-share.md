---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
---

## Instructions

1. Parse `$ARGUMENTS`: the first word is the target session, and the second word is the optional snapshot name.
2. If no target session is provided, tell the user: `Usage: /context-share <session-name> [snapshot-name]`.
3. If no snapshot name is provided, derive it from the current directory name.
4. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

5. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/share-context.sh" "<snapshot-name>" "<session-name>"
   ```

6. Report: `Shared session context '<snapshot-name>' with <session>. They can load it with /context-load <snapshot-name>.`
7. If the snapshot does not exist, suggest running `/context-generate` first.
