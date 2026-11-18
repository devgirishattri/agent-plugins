---
description: "Capture a low-friction memory candidate into the inbox for later consolidation, list pending candidates, or purge expired ones"
argument-hint: "[--store <path>] [--list [--expired-only] [--dismissed]] [<what to remember>]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this installed command file. Its parent is `<plugin-root>/commands`.
2. Read `<PLUGIN_ROOT>/skills/remember/SKILL.md` in full and follow it for the requested operation. Use its capture schema, evidence requirements, exit codes and separate approval steps for deletion.
3. Pass the user's arguments below to that skill, including `--store <path>` when supplied.

## User Request

$ARGUMENTS
