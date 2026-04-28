---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
---

## Instructions

1. Parse `$ARGUMENTS`: the first word is the target session name, and everything after it is the prompt.
2. If either value is missing, tell the user: `Usage: /dispatch <session-name> <task prompt>`.
3. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.5}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

4. Write the prompt to a temporary file, run the dispatch script, then remove the temp file:

   ```bash
   PROMPT_FILE=$(mktemp)
   printf '%s\n' "<prompt>" > "$PROMPT_FILE"
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" "<target>" "$PROMPT_FILE"
   rm -f "$PROMPT_FILE"
   ```

5. Report: `Dispatched task to **<target>**.`
6. If the target is not found, suggest `/panes` to show available sessions.
7. If there is an error about no name, tell the user to run `/whoami <name>` first.
