---
description: Load a session context summary from another session
argument-hint: <snapshot-name>
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: /context-load <snapshot-name>`.
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.6}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/load-context.sh" "$ARGUMENTS"
   ```

4. If the context loaded successfully, internalize it:
- What was done and what files changed.
- Key decisions and their reasoning.
- Open issues and where the other session left off.
- Notes and gotchas.

5. Summarize: `Loaded context from '<name>'. They were working on X and left off at Y.`
6. If no snapshot is found, suggest `/context-list`.
