---
description: Diff a context snapshot against its archived history versions
argument-hint: <snapshot-name> [--versions | <timestamp>]
allowed-tools: Bash(bash:*)
---

## Context Diff

!`export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"; bash ${CLAUDE_PLUGIN_ROOT}/scripts/diff-context.sh $ARGUMENTS`

## Instructions

Usage modes (all handled by the script above):
- `/context-diff <name>` — unified diff of the newest archived version against the current snapshot
- `/context-diff <name> --versions` — list available history timestamps (UTC, `YYYYMMDD-HHMMSSZ`)
- `/context-diff <name> <timestamp>` — diff that archived version against the current snapshot

Presenting the output:
- Show the unified diff in a fenced ```diff code block; briefly summarize what changed between versions.
- If the output says "(no differences)", state that the snapshot is unchanged since that version.
- If `--versions` was used, present the timestamps as a list and suggest `/context-diff <name> <timestamp>` to compare one.
- If no history versions exist yet, explain that history is only created when `/context-generate` overwrites an existing snapshot — saving the same name again will start the history.
- If the snapshot itself doesn't exist, suggest `/context-list` to see what's available.
