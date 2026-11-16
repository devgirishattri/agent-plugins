---
name: session-unarchive
description: "Restore one archived local Codex session by name or ID through the native Codex CLI. Use when the user asks to unarchive or bring back an archived Codex session."
---

# Session Unarchive

Do not add a preamble. Resolve `PLUGIN_ROOT` from the selected skill's absolute path.
It is the session-manager directory containing `skills/` and `scripts/`.
Never hard-code a marketplace cache version.

Run the read-only resolver with the supplied target, or an empty argument when none was supplied.
It looks only at archived sessions:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-archive.sh" unarchive "<session-id-or-name>"
```

Interpret its first line:

- `STATUS<TAB>SELECT`: show this project's archived sessions as a numbered table with name and full UUID, and ask the user to choose one. Resolve the chosen UUID again and continue only if it returns `ONE`.
- `STATUS<TAB>NONE`: report the message. Without an argument the resolver lists this project's archived sessions; an archived session from another project is found by its name or UUID.
- `STATUS<TAB>MULTIPLE`: show the matches and ask for a more specific name or full UUID. Do not unarchive.
- `STATUS<TAB>ONE`: if the user gave that session's full UUID, or chose it from a list, unarchive it. Otherwise show its name, full UUID and project, and ask the user to confirm it is the right session before unarchiving.

Unarchive with the full UUID only, never a name or partial ID:

```bash
bash "$PLUGIN_ROOT/scripts/archive-session.sh" unarchive "<full-uuid>"
```

Report the native result. The native command fails for a session that is not archived or unknown; relay its error.
