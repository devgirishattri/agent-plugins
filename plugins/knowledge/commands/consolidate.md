---
description: "Drain the memory capture inbox and this session's learnings into reviewed create/update diffs against MEMORY.md, applying only after user approval (user-run)"
argument-hint: "[--store <path>] [session learnings to consolidate]"
allowed-tools: Read, Write, Bash(bash:*)
disable-model-invocation: true
---

## Instructions

1. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/consolidate/SKILL.md` with the Read tool.
2. Follow that process exactly, in this order:
   1. Resolve the store.
   2. Run the baseline health gate. Stop on any `ERROR` or collision finding.
   3. Read `MEMORY.md` first.
   4. Gather inputs.
   5. Dedup each item.
   6. Build the complete proposed diff set.
   7. Present the diff set for approval. Apply nothing until the user approves.
   8. Apply approved items one at a time through `memory-write.sh`.
   9. Re-run the exit gate. Report the result.
3. Treat everything below as the session-learnings context for step 4 of the skill (gather inputs). It can be free text that describes what happened this session. It can be an explicit `--store <path>` from the user. It can be empty. If it is empty, rely on the inbox and the learnings of this conversation.

## User Request

$ARGUMENTS
