---
name: context-remove
description: "Remove a saved session context snapshot for the current Codex project."
---

# Context Remove

When this skill is invoked, do not add a preamble or narrate the plan. This action is destructive: never run the removal script before a separate explicit confirmation for the displayed snapshot.

Resolve `PLUGIN_ROOT` from this selected skill's absolute source path by going up two directories from `<plugin-root>/skills/context-remove/SKILL.md`. Never derive it from the project working directory or embed a cache version.

`SESSION_CONTEXT_HOME` is required by the scripts and is exported automatically by the command wrapper to `<git-root>/tmp/contexts` (or `<pwd>/tmp/contexts` when not in a git repo) unless already set.

If no snapshot name is provided:

1. Run `list-contexts.sh` and collect the first-column snapshot names.
2. If none exist, report that and suggest `$session-context:context-generate`; stop.
3. Ask the user to select a snapshot. Use structured `request_user_input` when it is available in the current mode and can represent the choices; otherwise ask one direct blocking question and wait. Do not infer a name.

For either a provided or selected name, show the exact name and ask a separate Yes/No confirmation before deletion. Prefer structured `request_user_input` when available, with `Cancel` as the recommended/default choice and `Remove` as the destructive choice; otherwise ask a direct blocking question. No response, ambiguity, or anything other than explicit `Remove`/yes means cancel. Do not combine selection and confirmation.

Only after explicit confirmation, run:

```bash
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/remove-context.sh" "<snapshot-name>" --confirmed
```

The `--confirmed` guard is a second line of defense and must be supplied only after the explicit confirmation above. Never infer, pre-fill, or bypass confirmation.

If the snapshot was removed, confirm the name and report how many archived history files were removed. Removal deletes the current snapshot and all matching `.history/<snapshot-name>.*.md` versions while leaving every other snapshot's history intact. If no snapshot is found, suggest `$session-context:context-list`. If cancelled, say no snapshot was removed and do not invoke the script.
