---
description: "[DEPRECATED — superseded by knowledge] Diff a context snapshot against its archived history versions"
argument-hint: <snapshot-name> [--versions | <timestamp>]
allowed-tools: Bash(bash:*)
---

## Context Diff

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/diff-context.sh" $ARGUMENTS`

## Instructions

- `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports it is not set, stop and request that this pane/session be relaunched with the correct environment — do not export the variable or derive another context store.
Usage modes (all handled by the script above):
- `/context-diff <name>` — unified diff of the newest archived version against the current snapshot
- `/context-diff <name> --versions` — list available history timestamps (`YYYYMMDD-HHMMSS+HHMM` in `AGENT_PLUGINS_TIME_ZONE`; legacy UTC timestamps remain accepted)
- `/context-diff <name> <timestamp>` — diff that archived version against the current snapshot

Presenting the output:
- Show the unified diff in a fenced ```diff code block; briefly summarize what changed between versions.
- If the output says "(no differences)", state that the snapshot is unchanged since that version.
- If `--versions` was used, present the timestamps as a list and suggest `/context-diff <name> <timestamp>` to compare one.
- If no history versions exist yet, explain that history is only created when `/context-generate` overwrites an existing snapshot — saving the same name again will start the history.
- If the snapshot itself doesn't exist, suggest `/context-list` to see what's available.
