---
name: whoami
description: "Show or set this Codex session's tmux pane name for session-chat messaging. Use when the user asks whoami, set my pane name, rename this pane, or wants other sessions to message this pane."
---

# Whoami

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.8}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Show the current pane name:

```bash
bash "$PLUGIN_ROOT/scripts/get-my-name.sh"
```

If the user provided a new name, validate that it only contains letters, numbers, hyphens, and underscores, then run:

```bash
bash -lc 'source "$0/scripts/lib.sh" && set_pane_name "$TMUX_PANE" "$1"' "$PLUGIN_ROOT" "<name>"
```

If this is not running inside tmux, explain that pane naming requires tmux and suggest starting one with `tmux new -s <name>`.
