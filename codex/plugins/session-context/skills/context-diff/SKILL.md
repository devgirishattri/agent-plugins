---
name: context-diff
description: "Diff a saved session context snapshot against its archived history versions for the current Codex project."
---

# Context Diff

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_CONTEXT_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Invoke the context helper as one literal Bash
segment, with no `export` beforehand, no `env` or variable-assignment prefix,
and no other command chained, piped, redirected, or substituted around it.

If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another context
store.

If no snapshot name is provided, tell the user:

```text
Usage: $session-context:context-diff <snapshot-name> [--versions | <timestamp>]
```

Run:

```bash
bash "<PLUGIN_ROOT>/scripts/diff-context.sh" "<snapshot-name>" [--versions | "<timestamp>"]
```

Modes:
- `<snapshot-name>` only — unified diff of the newest archived version against the current snapshot.
- `--versions` — list available history timestamps (IST, `YYYYMMDD-HHMMSS+0530`; legacy UTC timestamps remain accepted).
- `<timestamp>` — diff that archived version against the current snapshot.

Present the unified diff in a fenced code block and summarize the change briefly. If the output says "(no differences)", say the snapshot is unchanged. If no history versions exist, explain that history is only created when `$session-context:context-generate` overwrites an existing snapshot. If the snapshot does not exist, suggest `$session-context:context-list`.
