---
description: Permanently delete a Codex session through native Codex state management (no args = interactive select; --all = current project)
argument-hint: "[session-id-or-title | --all]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

The initial delete request, a session selection, and a message such as `delete <full-uuid>` are not final confirmation. Never run a destructive script until a separate final confirmation question has been answered affirmatively.

Use `request_user_input` for selections and confirmations when it is available in the current mode and can represent the choices. Otherwise ask one direct blocking question and wait for a later user response. Make `No, cancel (Recommended)` the first confirmation option and treat every response except an explicit affirmative as cancellation.

If `$ARGUMENTS` is exactly `--all`:

1. Run `bash "$PLUGIN_ROOT/scripts/list-sessions.sh"`.
2. If there are no session rows, report that and stop.
3. Show the rows and exact count. Warn that the active session is included and may be rewritten when it exits.
4. Ask a separate final confirmation with `No, cancel (Recommended)` and `Yes, delete all`.
5. Only after an explicit affirmative response, run `bash "$PLUGIN_ROOT/scripts/delete-all-sessions.sh" --confirmed` and report the native results.

For every other target, including empty input, run:

```bash
bash "$PLUGIN_ROOT/scripts/prepare-delete.sh" "$ARGUMENTS"
```

Handle the status:

- `SELECT`: show a numbered table and ask the user to choose a session. Resolve the selected full UUID again; selection is not confirmation.
- `NONE`: report the message and suggest `$session-manager:session-search` or `$session-manager:session-list`.
- `MULTIPLE`: show matches and ask for a more specific title or the full UUID.
- `ONE`: show title, full UUID, project, and size, then ask the separate final confirmation question.

Only after explicit affirmation of the final question for that displayed UUID, run:

```bash
bash "$PLUGIN_ROOT/scripts/delete-session.sh" "<full-uuid>" --confirmed
```

Never pass a title or partial ID to the destructive helper. On any non-affirmative answer, report `Deletion cancelled.`
