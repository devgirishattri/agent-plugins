---
name: session-archive
description: "Archive one local Codex session by name or ID through the native Codex CLI. Reversible with session-unarchive. Use when the user asks to archive, hide or set aside a Codex session without deleting it."
---

# Session Archive

Do not add a preamble. Resolve `PLUGIN_ROOT` from the selected skill's absolute path.
It is the session-manager directory containing `skills/` and `scripts/`.
Never hard-code a marketplace cache version.

Archiving is reversible: `$session-manager:session-unarchive` restores the
session. If the user wants the session gone for good, use
`$session-manager:session-delete` instead, which has its own confirmation.

Run the read-only resolver with the supplied target, or an empty argument when none was supplied.
It looks only at active sessions:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-archive.sh" archive "<session-id-or-name>"
```

Interpret its first line:

- `STATUS<TAB>SELECT`: show this project's active sessions as a numbered table with name and full UUID, and ask the user to choose one. Resolve the chosen UUID again and continue only if it returns `ONE`.
- `STATUS<TAB>NONE`: report the message and suggest `$session-manager:session-list` or `$session-manager:session-search <query>`.
- `STATUS<TAB>MULTIPLE`: show the matches and ask for a more specific name or full UUID. Do not archive.
- `STATUS<TAB>ONE`: if the user gave that session's full UUID, or chose it from a list, archive it. Otherwise show its name, full UUID and project, and ask the user to confirm it is the right session before archiving.

Archive with the full UUID only, never a name or partial ID:

```bash
bash "$PLUGIN_ROOT/scripts/archive-session.sh" archive "<full-uuid>"
```

Report the native result, and say that `$session-manager:session-unarchive <full-uuid>` brings it back.
The native command fails for a session that is already archived or unknown; relay its error.
