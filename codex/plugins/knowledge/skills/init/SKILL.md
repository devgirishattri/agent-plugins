---
name: init
description: "Bootstrap a new .agents/memory/ store for this repository through a reviewable two-call protocol."
---

# Init

This skill is explicitly invoked only. Resolve `PLUGIN_ROOT` from this selected
skill's installed source path: it is the directory two levels above this
`SKILL.md`. Substitute that absolute path literally below; never infer it from
the working directory or hardcode a marketplace cache version.

`init.sh` is a two-call PLAN/APPLY protocol with no state carried between
calls. Follow these steps in order and stop on any failure.

1. PLAN with one literal Bash segment (no `export`/`env`/assignment prefix,
   command substitution, chaining, piping, or redirection):

   ```bash
   bash "<PLUGIN_ROOT>/scripts/init.sh" [--store "<path>"]
   ```

   Pass `--store "<path>"` only when the user supplied one. A minimal
   `.gitignore` diff follows the pinned first line `target: <path>`. If output
   says the target is already covered, skip to step 3. Exit `3` is a resolution
   failure; relay stderr verbatim and stop.

2. Using the file-editing tool, not Bash, apply exactly the proposed
   `+<path>/` line to the `.gitignore` named by the diff, and show the applied
   diff. Do not modify any other line.

3. APPLY with the same optional `--store` value as PLAN:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/init.sh" [--store "<path>"] --apply
   ```

   Exit `0` reports `created: <path>` or `already initialized: <path>`; `3`
   means `.gitignore` coverage is still absent; `4` is an integrity refusal;
   `6` is reviewer-role or unresolved-fleet refusal. Relay the helper's message
   verbatim and never retry with a different path.

Never invoke `memory-write.sh bootstrap` directly; `init.sh` owns the
gitignore-coverage gate and propagates the writer's exit code unchanged.
