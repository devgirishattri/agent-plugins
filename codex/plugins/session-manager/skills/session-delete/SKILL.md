---
name: session-delete
description: "Delete a local Codex session after resolving and confirming a full session UUID."
---

# Session Delete

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.7}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

Run the delete resolver with the provided target, or with an empty argument if the user did not provide one:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-delete.sh" "<session-id-or-name>"
```

Interpret the first line:

- `STATUS<TAB>SELECT`: show the returned sessions as a numbered table with thread title and full session UUID, then ask which UUID to delete.
- `STATUS<TAB>NONE`: report that no session was found and suggest `$session-manager:session-list` or `$session-manager:session-search <query>`.
- `STATUS<TAB>MULTIPLE`: show the returned matches as a table and ask for the full UUID.
- `STATUS<TAB>ONE`: show the session details and ask the user to confirm by replying exactly `delete <full-uuid>`.

If the latest user message is exactly `delete <full-uuid>`, and the UUID has the full 36-character UUID format, run:

```bash
bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
```

Never delete by partial ID or display name.
