---
description: "Promote a stabilized context/handoff item or memory file into a memory create/UPDATE or a proposed docs patch, then separately approve source deletion (user-run)"
argument-hint: "[context <snapshot-name> | memory <slug>] [--store <path>]"
allowed-tools: Read, Write, Bash(bash:*)
disable-model-invocation: true
---

## Instructions

1. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/promote/SKILL.md` with the Read tool.
2. Follow that process exactly, in this order:
   1. Identify the source.
   2. Resolve the relevant store or stores.
   3. Read the source in full.
   4. Propose the destination: a memory apply-path, or a docs proposed-patch-only.
   5. Carry through any ticket citations honestly.
   6. Present the destination proposal for approval.
   7. Write the destination and revalidate it.
   8. Delete the source. This is a SEPARATE step with its own approval. Delete a context source through `remove-context.sh`. Delete a memory source through `memory-write.sh retire`.
3. Never write a docs destination directly. It is always a proposed patch that the user applies.
4. Treat everything below as the source and destination context of this run. It can name an item to promote: a context snapshot or handoff name, or a memory file slug for a supersession. It can be an explicit `--store <path>`. It can be empty. If it is empty, ask which source this run promotes, per skill step 1.

## User Request

$ARGUMENTS
