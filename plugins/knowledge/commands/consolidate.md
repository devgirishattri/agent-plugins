---
description: "Drain the memory capture inbox and this session's learnings into reviewed create/update diffs against MEMORY.md, applying only after user approval (user-run)"
argument-hint: "[--store <path>] [session learnings to consolidate]"
allowed-tools: Read, Write, Bash(bash:*)
disable-model-invocation: true
---

## Instructions

1. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/consolidate/SKILL.md` using the Read tool.
2. Follow that process exactly, in order: resolve the store, run the baseline health gate (stop on any `ERROR`/collision finding), read `MEMORY.md` first, gather inputs, dedup each item, build the complete proposed diff set, present it for approval, apply nothing until approved, apply approved items one at a time through `memory-write.sh`, then re-run the exit gate and report.
3. Treat everything below as the session-learnings context for step 4 of the skill (gathering inputs) — free text describing what happened this session, an explicit `--store <path>` if the user supplied one, or nothing at all (in which case rely on the inbox and this conversation's own learnings).

## User Request

$ARGUMENTS
