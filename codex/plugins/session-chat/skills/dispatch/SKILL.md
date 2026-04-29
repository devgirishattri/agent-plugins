---
name: dispatch
description: "Dispatch a task prompt to another named tmux pane through session-chat. Use when the user asks to assign work, dispatch a task, or send a tracked task to another Codex session."
---

# Dispatch

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.7}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Parse the first argument as the target pane name and the rest as the task prompt. If either is missing, tell the user:

```text
Usage: $session-chat:dispatch <pane-name> <task prompt>
```

Run:

```bash
PROMPT_FILE=$(mktemp)
printf '%s\n' "<prompt>" > "$PROMPT_FILE"
bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" "<target>" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

If tmux is not active, explain that dispatch requires running Codex inside tmux.
