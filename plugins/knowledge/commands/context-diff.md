---
description: Diff a context snapshot against its archived history versions
argument-hint: <snapshot-name> [--versions | <timestamp>]
allowed-tools: Bash(bash:*)
---

## Context Diff

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/diff-context.sh" $ARGUMENTS`

## Instructions

`SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports that it is not set, stop. Ask the user to relaunch this pane or session with the correct environment. Do not export the variable. Do not derive another context store.

Usage modes (the script above handles all of them):
- `/context-diff <name>` — unified diff of the newest archived version against the current snapshot
- `/context-diff <name> --versions` — list available history timestamps (`YYYYMMDD-HHMMSS+HHMM` in `AGENT_PLUGINS_TIME_ZONE`; legacy UTC timestamps remain accepted)
- `/context-diff <name> <timestamp>` — diff that archived version against the current snapshot

Present the output by case. Lead with the result.

| Output | What to tell the user |
|---|---|
| A diff | Show the unified diff in a fenced ```diff code block. Summarize briefly what changed between versions. |
| "(no differences)" | The snapshot is unchanged since that version. |
| `--versions` list | Present the timestamps as a list. Suggest `/context-diff <name> <timestamp>` to compare one. |
| No history versions | History exists only after `/context-generate` overwrites an existing snapshot. Saving the same name again starts the history. |
| The snapshot does not exist | Suggest `/context-list` to see what is available. |
