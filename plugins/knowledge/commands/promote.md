---
description: "Promote a stabilized context/handoff item or memory file into a memory create/UPDATE or a proposed docs patch, then separately confirm source deletion (user-run)"
argument-hint: "[context <snapshot-name> | memory <slug>] [--store <path>]"
allowed-tools: Read, Write, Bash(bash:*)
disable-model-invocation: true
---

## Instructions

1. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/promote/SKILL.md` using the Read tool.
2. Follow that process exactly, in order: identify the source, resolve the relevant store(s), read the source in full, propose the destination (memory apply-path or docs proposed-patch-only), carry through any ticket citations honestly, present the destination proposal for approval, write + revalidate the destination, then — only as a SEPARATE, separately confirmed step — delete the source (context via `remove-context.sh`, memory via `memory-write.sh retire`). Never write a docs destination directly; it is always a proposed patch the user applies themselves.
3. Treat everything below as this run's source/destination context: which item to promote (a context snapshot/handoff name, or a memory file slug for a supersession), an explicit `--store <path>` if given, or nothing at all (in which case ask which source this run promotes, per skill step 1).

## User Request

$ARGUMENTS
