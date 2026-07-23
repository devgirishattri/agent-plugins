---
description: "Drain the memory capture inbox and this session's learnings into reviewed create/update diffs against MEMORY.md, applying only after user approval (user-run)"
argument-hint: "[--store <path>] [session learnings to consolidate]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's installed absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Never derive it from the project working directory or hardcode a marketplace cache version.
2. Read `<PLUGIN_ROOT>/skills/consolidate/SKILL.md` in full with the file-reading tool.
3. Follow that process exactly, in order: resolve the store, run the baseline health gate (stop on any `ERROR`/collision finding), read `MEMORY.md` first, gather inputs, dedup each item, build the complete proposed diff set, present it for approval, apply nothing until approved, apply approved items one at a time through `memory-write.sh`, then re-run the exit gate and report.
4. Treat everything below as the session-learnings context for the skill's input-gathering step: free text describing what happened this session, an explicit `--store <path>` if the user supplied one, or nothing at all (in which case rely on the inbox and this conversation's own learnings).

## User Request

$ARGUMENTS
