---
description: Dispatch a task to a new tmux worker pane with a full Claude session
argument-hint: <prompt> [--model sonnet|opus|haiku] [--label name]
allowed-tools: Bash(bash:*)
---

## Instructions

1. Parse $ARGUMENTS:
   - Extract `--model` flag (default: sonnet)
   - Extract `--label` flag (auto-generate 6-char hex if not provided: `head -c3 /dev/urandom | od -An -tx1 | tr -d ' '`)
   - Everything else is the prompt text

2. Write the prompt to a temp file:
   ```
   PROMPT_FILE=$(mktemp)
   echo "<prompt text>" > "$PROMPT_FILE"
   ```

3. Run the create-worker script:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/create-worker.sh "<label>" "$PROMPT_FILE" "<model>" "$(pwd)"
   ```

4. Clean up the temp file

5. Report: "Dispatched task '<label>' to worker pane using <model>."

6. If the script errors about no name, tell the user to run `/whoami <name>` first.
