---
name: session-delete
description: "Delete a local Codex session by resolving a title, ID, or project query to exactly one session."
---

# Session Delete

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-manager/1.4.7}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-manager"
```

Run the delete-and-resolve helper with the provided target, or with an empty argument if the user did not provide one:

```bash
bash "$PLUGIN_ROOT/scripts/delete-resolved-session.sh" "<session-id-or-title>"
```

Interpret the first line:

- `STATUS<TAB>SELECT`: show the returned sessions as a numbered table with thread title and full session UUID, then ask which UUID to delete.
- `STATUS<TAB>NONE`: report that no session was found and suggest `$session-manager:session-list` or `$session-manager:session-search <query>`.
- `STATUS<TAB>MULTIPLE`: show the returned matches as a table and ask for a more specific title or the full UUID.
- `STATUS<TAB>DELETING`: report the deletion output.

If the latest user message is exactly `delete <full-uuid>`, and the UUID has the full 36-character UUID format, keep backwards compatibility by running:

```bash
bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>"
```

Never pass a partial ID or display name directly to `delete-session.sh`; resolve it through `delete-resolved-session.sh` first.
