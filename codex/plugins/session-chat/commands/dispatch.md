---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
---

## Instructions

1. Parse `$ARGUMENTS`: optional `--priority high` and `--ttl <minutes>` come first; then the target session name; everything after is the prompt.
2. If either value is missing, tell the user: `Usage: /dispatch <session-name> <task prompt>`.
3. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.15.2}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
   ```

4. Write the prompt to a temporary file, run the dispatch script, then remove the temp file:

   ```bash
   PROMPT_FILE=$(mktemp)
   cat > "$PROMPT_FILE" <<'EOF'
   <prompt>
   EOF
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" [--priority high] [--ttl <minutes>] "<target>" "$PROMPT_FILE"
   rm -f "$PROMPT_FILE"
   ```

5. Report: `Dispatched task to **<target>**. The recipient must use SESSION_CHAT_INCOMING_MODE=auto or assist to read and act on the task; the default notify mode only reports that a dispatch arrived.`
6. If the target is not found, suggest `/panes` to show available sessions.
7. If there is an error about no name, tell the user to run `/whoami <name>` first.
8. If there is an error about multiple panes with the same name, tell the user to rename one of those panes with `/whoami <name>`.
9. If there is an error that the dispatch did not land within the timeout, tell the user the target may be busy; retry when idle or raise `SESSION_CHAT_VERIFY_TIMEOUT_MS`.
