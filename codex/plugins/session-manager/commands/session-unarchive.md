---
description: Restore an archived Codex session through the native Codex command (no args = choose from this project's archived sessions)
argument-hint: "[session-id-or-name]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

Run the read-only resolver with `$ARGUMENTS`, or an empty argument when none was supplied. It looks only at archived sessions:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-archive.sh" unarchive "$ARGUMENTS"
```

Handle the status:

- `SELECT`: show a numbered table of this project's archived sessions and ask the user to choose one. Resolve the chosen full UUID again.
- `NONE`: report the message. Without an argument the resolver lists this project's archived sessions; an archived session from another project is found by its name or UUID.
- `MULTIPLE`: show the matches and ask for a more specific name or the full UUID.
- `ONE`: if the user gave that session's full UUID, or chose it from a list, unarchive it. Otherwise show its name, full UUID and project and ask the user to confirm it is the right session first.

Unarchive with the full UUID only:

```bash
bash "$PLUGIN_ROOT/scripts/archive-session.sh" unarchive "<full-uuid>"
```

Report the native result. Never pass a name or partial ID to `archive-session.sh`.
