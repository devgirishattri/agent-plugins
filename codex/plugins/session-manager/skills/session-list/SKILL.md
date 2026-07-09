---
name: session-list
description: "List local Codex sessions for the current project or all projects. Use when the user asks to list sessions or inspect recent Codex sessions."
---

# Session List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-manager/1.7.1}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

Run one of:

```bash
bash "$PLUGIN_ROOT/scripts/list-sessions.sh"
bash "$PLUGIN_ROOT/scripts/list-sessions.sh" all
```

Present tab-separated output as:

```text
| Thread | Session ID | Project | Size | Last Modified |
```

Show full session IDs and a total count. The first column is the Codex thread title from `~/.codex/state_5.sqlite`, falling back to the first user message only when the thread title is unavailable.
