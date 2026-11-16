---
description: Archive a Codex session through the native Codex command (reversible; no args = choose from this project)
argument-hint: "[session-id-or-name]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

Archiving is reversible: `$session-manager:session-unarchive` restores the session. Use `$session-manager:session-delete` only when the user wants the session gone for good.

Run the read-only resolver with `$ARGUMENTS`, or an empty argument when none was supplied:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-archive.sh" archive "$ARGUMENTS"
```

Handle the status:

- `SELECT`: show a numbered table of this project's active sessions and ask the user to choose one. Resolve the chosen full UUID again.
- `NONE`: report the message and suggest `$session-manager:session-list` or `$session-manager:session-search`.
- `MULTIPLE`: show the matches and ask for a more specific name or the full UUID.
- `ONE`: if the user gave that session's full UUID, or chose it from a list, archive it. Otherwise show its name, full UUID and project and ask the user to confirm it is the right session first.

Archive with the full UUID only:

```bash
bash "$PLUGIN_ROOT/scripts/archive-session.sh" archive "<full-uuid>"
```

Report the native result and tell the user that `$session-manager:session-unarchive <full-uuid>` brings it back. Never pass a name or partial ID to `archive-session.sh`.
