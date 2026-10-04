---
description: "Promote a stabilized context/handoff item or memory file into a memory create/UPDATE or a proposed docs patch, then separately approve source deletion (user-run)"
argument-hint: "[context <snapshot-name> | memory <slug>] [--store <path>]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's installed absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Never derive it from the project working directory or hardcode a marketplace cache version.
2. Read `<PLUGIN_ROOT>/skills/promote/SKILL.md` in full with the file-reading tool.
3. Follow the skill process in order. Identify the source, resolve the relevant stores, read the source, and propose the destination. Carry ticket citations honestly. Get approval for the destination, then write and revalidate it. Delete the source only as a separate step with its own approval: context uses `remove-context.sh`; memory uses `memory-write.sh retire`. Docs destinations remain proposed patches for the user to apply. Never write them directly.
4. Treat everything below as this run's source/destination context: which item to promote (a context snapshot/handoff name, or a memory-file slug for a supersession), an explicit `--store <path>` if given, or nothing at all (in which case ask which source this run promotes, per skill step 1).

## User Request

$ARGUMENTS
