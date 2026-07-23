---
description: "Promote a stabilized context/handoff item or memory file into a memory create/UPDATE or a proposed docs patch, then separately confirm source deletion (user-run)"
argument-hint: "[context <snapshot-name> | memory <slug>] [--store <path>]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's installed absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Never derive it from the project working directory or hardcode a marketplace cache version.
2. Read `<PLUGIN_ROOT>/skills/promote/SKILL.md` in full with the file-reading tool.
3. Follow that process exactly, in order: identify the source, resolve the relevant store(s), read the source in full, propose the destination (memory apply-path or docs proposed-patch-only), carry through any ticket citations honestly, present the destination proposal for approval, write and revalidate the destination, then—only as a separate, separately confirmed step—delete the source (context via `remove-context.sh`, memory via `memory-write.sh retire`). Never write a docs destination directly; it is always a proposed patch the user applies themselves.
4. Treat everything below as this run's source/destination context: which item to promote (a context snapshot/handoff name, or a memory-file slug for a supersession), an explicit `--store <path>` if given, or nothing at all (in which case ask which source this run promotes, per skill step 1).

## User Request

$ARGUMENTS
