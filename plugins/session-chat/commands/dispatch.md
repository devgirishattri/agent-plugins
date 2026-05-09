---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

`/dispatch` is for **task hand-off** — multi-line prompts, code, structured work. The full prompt is written to a file under `~/.claude/messages/` and the recipient gets a one-line notification with the file path. See the `session-chat` skill for the full contract, recipient prerequisites, and `INCOMING_MODE` requirements.

1. Parse $ARGUMENTS: first word is the target session name, everything after is the prompt.

2. If $ARGUMENTS is empty or has no prompt after the session name, ask the user:
   "Usage: `/dispatch <session-name> <task prompt>`"

3. Run the dispatch script. Use a heredoc (not `echo`) to preserve newlines and special chars:
   ```
   PROMPT_FILE=$(mktemp)
   cat > "$PROMPT_FILE" <<'PROMPT_EOF'
<prompt body verbatim>
PROMPT_EOF
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh "<target>" "$PROMPT_FILE"
   rm -f "$PROMPT_FILE"
   ```

4. Report: "Dispatched task to **<target>**. Use `/panes` to check status or `/send <target> <message>` to follow up. Note: if `<target>` runs with `SESSION_CHAT_INCOMING_MODE=notify` (default) they will be **told not to read** the dispatch file — set `auto` or `assist` for orchestration."

5. If error about target not found, run `/panes` to show available sessions.
6. If error about no name, tell user to run `/whoami <name>` first.
7. If error mentions duplicate names, ask the user to rename one pane via `/whoami`.
8. If "did not land within Xms", retry once after a short pause; if it persists raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` (recipient may be in a long-running TUI frame).
