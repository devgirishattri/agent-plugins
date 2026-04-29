---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
allowed-tools: Bash(bash:*)
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

1. Parse $ARGUMENTS: first word is the target session name, everything after is the prompt.

2. If $ARGUMENTS is empty or has no prompt after the session name, ask the user:
   "Usage: `/dispatch <session-name> <task prompt>`"

3. Run the dispatch script with properly quoted arguments:
   ```
   PROMPT_FILE=$(mktemp)
   echo "<prompt>" > "$PROMPT_FILE"
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh "<target>" "$PROMPT_FILE"
   rm -f "$PROMPT_FILE"
   ```

4. Report: "Dispatched task to **<target>**. Use `/panes` to check their status, or `/send <target> <message>` to follow up."

5. If error about target not found, run `/panes` to show available sessions.
6. If error about no name, tell user to run `/whoami <name>` first.
