---
description: "Bootstrap a new .agents/memory/ store for this repository"
argument-hint: "[--store <path>]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path: its
   parent is `<plugin-root>/commands`, so go up one directory. Never derive it
   from the project working directory or embed a marketplace cache version.

2. `init.sh` is a two-call PLAN/APPLY protocol with no state carried between
   calls. PLAN first, using exactly one literal Bash segment (no
   `export`/`env`/assignment prefix, command substitution, chaining, piping, or
   redirection):

   ```bash
   bash "<PLUGIN_ROOT>/scripts/init.sh" [--store "<path>"]
   ```

   Pass `--store "<path>"` only when the user supplied one. Exit `0` with
   `(already covered by .gitignore — re-run with --apply)` skips to step 4.
   Exit `0` with a minimal `.gitignore` diff after `target: <path>` continues
   to step 3. Exit `3` is a resolution failure; relay stderr verbatim and stop.

3. Using the file-editing tool, not Bash, apply exactly the proposed
   `+<path>/` line to the `.gitignore` named by the diff and show the applied
   diff. Do not modify any other line.

4. Run APPLY as one literal Bash segment with the same optional `--store`
   value used in PLAN:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/init.sh" [--store "<path>"] --apply
   ```

   Exit `0` reports either `created: <path>` or
   `already initialized: <path>`. Exit `3` means the target is not yet covered
   by `.gitignore`; exit `4` is a store-integrity failure; exit `6` is reviewer
   or unresolved-fleet refusal. Relay the helper's message verbatim and do not
   retry with a different target. Never invoke `memory-write.sh bootstrap`
   directly from this command.

## User Request

Arguments: `$ARGUMENTS`
