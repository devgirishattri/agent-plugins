---
description: Dispatch a tracked task to an existing session or a new worker pane
argument-hint: [target-session] <prompt> [--model sonnet|opus|haiku] [--label name]
allowed-tools: Bash(bash:*)
---

## Named Panes

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/list-panes.sh`

## Instructions

1. Parse $ARGUMENTS and determine the dispatch mode:

   **Mode A — Existing session**: If the first word matches a named pane from the list above, dispatch TO that session.
   - Target = first word, prompt = everything after
   - Run:
     ```
     PROMPT_FILE=$(mktemp)
     echo "<prompt>" > "$PROMPT_FILE"
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh "<target>" "$PROMPT_FILE"
     rm -f "$PROMPT_FILE"
     ```
   - Report: "Dispatched task to **<target>**. Track with `/dispatch-status`."

   **Mode B — New worker**: If the first word does NOT match any named pane, create a new worker pane.
   - Extract `--model` flag (default: sonnet)
   - Extract `--label` flag (auto-generate 6-char hex if not provided)
   - Prompt = everything that's not a flag
   - Run:
     ```
     PROMPT_FILE=$(mktemp)
     echo "<prompt>" > "$PROMPT_FILE"
     bash ${CLAUDE_PLUGIN_ROOT}/scripts/create-worker.sh "<label>" "$PROMPT_FILE" "<model>" "$(pwd)"
     rm -f "$PROMPT_FILE"
     ```
   - Report: "Dispatched new worker **<label>** using <model>."

2. If error about no name, tell user to run `/whoami <name>` or `/rename <name>` first.
3. If target not found, show the available panes from above.
