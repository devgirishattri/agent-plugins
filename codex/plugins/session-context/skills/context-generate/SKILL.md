---
name: context-generate
description: "Generate a concise context snapshot for the current Codex session or project so another session can continue the work."
---

# Context Generate

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

Generate a snapshot under 150 lines. Include relevant sections only:

```text
# Session Context: <name>
Generated: YYYY-MM-DD HH:MM
Project: <current directory>

## What Was Done
## Files Changed
## Key Decisions
## Open Issues
## Where I Left Off
## Notes for Next Session
```

Use the provided snapshot name, or derive one from the current directory. Save it with:

```bash
bash "<PLUGIN_ROOT>/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
```

Before writing the snapshot, gather concise context from recent git history and local docs when available:

```bash
git diff --stat HEAD
git log --oneline -10
git diff --name-only HEAD~5..HEAD
```

Saving over an existing snapshot archives the previous version under
`SESSION_CONTEXT_HOME/.history/` automatically (the 10 most recent versions are
kept); compare versions with `$session-context:context-diff <snapshot-name>`.

After saving, report the snapshot name and mention `$session-context:context-share <session> <snapshot-name>` and `$session-context:context-load <snapshot-name>`.
