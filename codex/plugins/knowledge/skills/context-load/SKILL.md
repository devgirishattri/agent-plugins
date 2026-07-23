---
name: context-load
description: "Load a previously saved session context snapshot into the current Codex session."
---

# Context Load

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
Usage: $knowledge:context-load <snapshot-name>
```

Run:

```bash
bash "<PLUGIN_ROOT>/scripts/load-context.sh" "<snapshot-name>"
```

Internalize the loaded context, especially what was done, files changed, decisions, open issues, and where the prior session left off. Summarize what was loaded. If a staleness WARNING appears at the end of the output (snapshot 7 or more days old, configurable via `SESSION_CONTEXT_STALE_DAYS`), surface it and suggest regenerating with `$knowledge:context-generate`. If no snapshot is found, suggest `$knowledge:context-list`.
