---
name: context-remove
description: "Remove a saved session context snapshot for the current Codex project."
---

# Context Remove

When this skill is invoked, do not add a preamble or narrate the plan. This action is destructive: never run the removal script before a separate explicit confirmation for the displayed snapshot.

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_CONTEXT_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Invoke each context helper as one literal Bash
segment, with no `export` beforehand, no `env` or variable-assignment prefix,
and no other command chained, piped, redirected, or substituted around it.

If a script reports `SESSION_CONTEXT_HOME` is not set, stop and request a pane
relaunch with the correct environment instead of deriving another context store.

If no snapshot name is provided:

1. Run `list-contexts.sh` and collect the first-column snapshot names.
2. If none exist, report that and suggest `$knowledge:context-generate`; stop.
3. Ask the user to select a snapshot. Use structured `request_user_input` when it is available in the current mode and can represent the choices; otherwise ask one direct blocking question and wait. Do not infer a name.

For either a provided or selected name, require it to match
`^[A-Za-z0-9_-]+$` before interpolating it into any path; reject any other value
without previewing or removing it. Then produce a point-in-time preview of
exactly the files currently visible to read-only filesystem inspection:
enumerate the current `$SESSION_CONTEXT_HOME/<snapshot-name>.md` file and every
matching `$SESSION_CONTEXT_HOME/.history/<snapshot-name>.*.md` file. Show the
exact paths and history-file count without invoking `remove-context.sh`. If
neither current nor archived data exists, suggest `$knowledge:context-list`
and stop. Explain that the removal helper later revalidates under its writer lock,
so a concurrent overwrite may add history after this preview and the helper's
final removal count is authoritative.

Then show the exact name and ask a separate Yes/No confirmation before deletion.
Prefer structured `request_user_input` when available, with `Cancel` as the
recommended/default choice and `Remove` as the destructive choice; otherwise
ask a direct blocking question. No response, ambiguity, or anything other than
explicit `Remove`/yes means cancel. Do not combine selection and confirmation.

Only after explicit confirmation, run:

```bash
bash "<PLUGIN_ROOT>/scripts/remove-context.sh" "<snapshot-name>" --confirmed
```

The `--confirmed` guard is a second line of defense and must be supplied only after the explicit confirmation above. Never infer, pre-fill, or bypass confirmation.

If the snapshot was removed, confirm the name and report how many archived history files were removed. Removal deletes the current snapshot and all matching `.history/<snapshot-name>.*.md` versions while leaving every other snapshot's history intact. If no snapshot is found, suggest `$knowledge:context-list`. If cancelled, say no snapshot was removed and do not invoke the script.
