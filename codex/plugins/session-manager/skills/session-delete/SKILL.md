---
name: session-delete
description: "Permanently delete one local Codex session by name, ID, or project query, or bulk-delete the current project's sessions with --all. Use only for user-requested deletion and require a separate explicit final confirmation before any destructive command."
---

# Session Delete

Do not add a preamble. Resolve `PLUGIN_ROOT` from the selected skill's absolute path: it is the session-manager directory containing `skills/` and `scripts/`. Never hard-code a marketplace cache version.

Treat the user's initial deletion request as intent to start the flow, not as final confirmation. Never delete until a separate final confirmation question has been answered affirmatively; identification or selection alone is insufficient.

For a selection or confirmation:

- Use `request_user_input` when it is available in the current mode and can represent the choices.
- Otherwise, ask one direct blocking question and stop. Do not run a deletion command until the user answers in a later turn.
- Make cancellation the default. For final confirmation, put `No, cancel (Recommended)` before `Yes, delete it` (or `Yes, delete all`). Treat anything except an explicit affirmative answer to that final question as cancellation.

## Delete all sessions for the current project

When the target is exactly `--all`, run:

```bash
bash "$PLUGIN_ROOT/scripts/delete-all-sessions.sh" --plan
```

If preflight fails, report its diagnostic and stop. Show the project, ELIGIBLE
rows and count, and SKIP rows with their reasons separately. If there are no
eligible rows, report that and stop without asking for deletion confirmation.
Warn that eligible active sessions may fail deletion while in use, then ask the
final confirmation question for the eligible sessions in this project. Only
after an explicit affirmative answer, run:

```bash
bash "$PLUGIN_ROOT/scripts/delete-all-sessions.sh" --confirmed
```

Report the native Codex results. On any other answer, report `Deletion cancelled.`

Bulk deletion performs a native preflight before beginning the batch, then
rechecks each eligible UUID immediately before deletion and requires an exact
match to the approved project. Filesystem-only rows are skipped, with reasons;
they never authorize deletion. Missing native metadata and a changed project
binding have distinct errors. Report the final deleted, failed, and skipped
counts and failed UUIDs; do not describe skipped sessions as deleted.

Native lookup first tries the existing shared server, then a temporary stdio
app server that is closed after the lookup. No manual daemon startup is needed.
If both connections fail, or `SESSION_MANAGER_BACKEND=filesystem` is selected,
preflight refuses the batch. Relay the diagnostic; do not change the backend
environment implicitly. Deletion itself stays with the native Codex CLI.

## Delete one session

Run the read-only resolver with the supplied target, or an empty argument when none was supplied:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-delete.sh" "<session-id-or-name>"
```

Interpret its first line:

- `STATUS<TAB>SELECT`: show the sessions as a numbered table with name and full UUID. Ask the user to select one. If structured input cannot fit all choices, ask for the number or full UUID directly. After selection, resolve the chosen UUID again and continue only if it returns `ONE`.
- `STATUS<TAB>NONE`: report the message and suggest `$session-manager:session-list` or `$session-manager:session-search <query>`.
- `STATUS<TAB>MULTIPLE`: show the matches and ask for a more specific name or full UUID. Do not delete.
- `STATUS<TAB>ONE`: show the name, full UUID, project, and size, then ask the separate final confirmation question.

Selection never counts as final confirmation. A message such as `delete <full-uuid>` also starts this flow and never bypasses confirmation.

Only after the user explicitly affirms the final question for the displayed UUID, run:

```bash
bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>" --confirmed
```

The helper validates the UUID and delegates to the native `codex delete --force` command. Never pass a name or partial ID to it. Report native output, or `Deletion cancelled.` for every non-affirmative response.
