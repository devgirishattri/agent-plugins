---
name: session-chat
description: "Use this skill when the user wants to coordinate Codex sessions through tmux: name panes, list named panes, send messages, dispatch tasks, generate/list/load/share context snapshots, or use workflows formerly described as /whoami, /panes, /send, /dispatch, /context-generate, /context-list, /context-load, and /context-share."
---

# Session Chat

Use this skill for tmux-based coordination between Codex sessions. Resolve the plugin root first:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.9.4}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Most workflows require running inside tmux.

## Name Or Inspect This Pane

Show current name:

```bash
bash "$PLUGIN_ROOT/scripts/get-my-name.sh"
```

Set a name after validating it contains only letters, numbers, hyphens, and underscores:

```bash
bash -lc 'source "$0/scripts/lib.sh" && set_pane_name "$TMUX_PANE" "$1"' "$PLUGIN_ROOT" "<name>"
```

## List Named Panes

```bash
bash "$PLUGIN_ROOT/scripts/list-panes.sh"
```

Present tab-separated output as:

```text
| Name | Pane | Command | Location |
```

## Send A Message

Parse the first word as the target pane name and the rest as the message:

```bash
bash "$PLUGIN_ROOT/scripts/send-message.sh" "<target-name>" "<message>"
```

## Dispatch A Task

Write the task prompt to a temp file, dispatch it, then remove the temp file:

```bash
PROMPT_FILE=$(mktemp)
printf '%s\n' "<prompt>" > "$PROMPT_FILE"
bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" "<target>" "$PROMPT_FILE"
rm -f "$PROMPT_FILE"
```

## Context Snapshots

List snapshots:

```bash
bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
```

Load a snapshot:

```bash
bash "$PLUGIN_ROOT/scripts/load-context.sh" "<snapshot-name>"
```

Save generated context:

```bash
bash "$PLUGIN_ROOT/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
```

Share context with another named pane:

```bash
bash "$PLUGIN_ROOT/scripts/share-context.sh" "<snapshot-name>" "<session-name>"
```

When generating a snapshot, keep it under 150 lines and include only relevant sections:

```text
# Session Context: <name>
Generated: YYYY-MM-DD HH:MM
Project: <current directory>

## What Was Done
## Files Changed
## Key Decisions
## Open Issues
## Where I Left Off
## Notes for Next Session
```
