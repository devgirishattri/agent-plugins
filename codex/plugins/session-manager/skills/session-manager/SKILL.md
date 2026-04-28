---
name: session-manager
description: "Use this skill when the user wants to list, search, inspect, or delete local Codex sessions. Trigger for requests like list sessions, find old Codex sessions, search sessions by project, delete this session, or references to /session-list, /session-search, and /session-delete."
---

# Session Manager

Use the plugin scripts to inspect local Codex session data. Resolve the plugin root first:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.4}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

## List Sessions

For current project sessions:

```bash
bash "$PLUGIN_ROOT/scripts/list-sessions.sh"
```

For all projects:

```bash
bash "$PLUGIN_ROOT/scripts/list-sessions.sh" all
```

Present tab-separated output as:

```text
| Name | Session ID | Project | Size | Last Modified |
```

Show full session IDs and a total count.

## Search Sessions

```bash
bash "$PLUGIN_ROOT/scripts/search-sessions.sh" "<query>"
```

Search matches title, session ID, and project path. If no query is provided, tell the user:

```text
Usage: $session-manager search <name-or-id-or-project>
```

## Delete Sessions

Deletion must be explicit and confirmed. First resolve the target:

```bash
bash "$PLUGIN_ROOT/scripts/find-or-skip.sh" "<session-id-or-name>"
```

If exactly one session matches, show its details and ask for confirmation. Only pass a full UUID to the delete script:

```bash
bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
```

Never delete by partial ID or display name.
