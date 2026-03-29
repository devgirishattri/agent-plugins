---
description: Dispatch a tracked task to an existing session or a new worker pane
argument-hint: [target-session] <prompt> [--model sonnet|opus|haiku] [--label name]
allowed-tools: Bash(bash:*)
---

## Instructions

1. First, check if the first word of $ARGUMENTS is an existing named pane by running:
   ```
   tmux list-panes -a -F '#{@name}' 2>/dev/null | grep -qx "<first-word>"
   ```

2. **If the first word matches an existing pane name** → dispatch TO that session:
   - Target = first word, prompt = everything after the first word
   - Run:
     ```
     PROMPT_FILE=$(mktemp)
     echo "<prompt>" > "$PROMPT_FILE"
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh "<target>" "$PROMPT_FILE"
     rm -f "$PROMPT_FILE"
     ```
   - Report: "Dispatched task to **<target>**. Track with `/dispatch-status`."

3. **If the first word does NOT match any pane** → create a new worker pane:
   - Extract `--model` flag (default: sonnet)
   - Extract `--label` flag (auto-generate if not provided: `head -c3 /dev/urandom | od -An -tx1 | tr -d ' '`)
   - Prompt = everything that's not a flag
   - Run:
     ```
     PROMPT_FILE=$(mktemp)
     echo "<prompt>" > "$PROMPT_FILE"
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/create-worker.sh "<label>" "$PROMPT_FILE" "<model>" "$(pwd)"
     rm -f "$PROMPT_FILE"
     ```
   - Report: "Dispatched new worker **<label>** using <model>."

4. If error about no name, tell user to run `/whoami <name>` or `/rename <name>` first.
