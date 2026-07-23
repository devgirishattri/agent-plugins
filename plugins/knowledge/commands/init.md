---
description: "Bootstrap a new .agents/memory/ store for this repository"
argument-hint: "[--store <path>]"
allowed-tools: Read, Edit, Bash(bash:*)
disable-model-invocation: true
---

## Instructions

`init.sh` is a two-call PLAN/APPLY protocol; no state is carried between the calls (the target resolution is deterministic, so both calls derive the same path). Follow these steps in order and stop immediately if any step fails.

1. **Plan.** Run exactly one literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection); pass `--store <path>` only if the user supplied one in `$ARGUMENTS`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" [--store <path>]
   ```
   - Exit `0` with a line `(already covered by .gitignore — re-run with --apply)`: the store's `.gitignore` coverage is already in place — skip straight to step 3.
   - Exit `0` with a `--- a/...` / `+++ b/...` / `@@` / `+<path>/` diff following the `target: <path>` line: this is the proposed `.gitignore` addition. Continue to step 2.
   - Exit `3`: not inside a git repository (or another resolution failure) — relay the stderr message verbatim and stop.

2. **Apply the proposed `.gitignore` line.** Using the Read/Edit tools (not Bash), add the exact proposed line (the `+<path>/` content, e.g. `.agents/memory/`) to the `.gitignore` file named in the diff's `+++ b/<path>` line, creating the file if it does not exist. Show the user the diff you applied.

3. **Bootstrap.** Run exactly one literal Bash segment with the SAME `--store` argument (if any) used in step 1, plus `--apply`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/init.sh" [--store <path>] --apply
   ```
   - Exit `0` with `created: <path>`: the store now exists (empty `MEMORY.md`, `0700`/`0600` permissions). Report success.
   - Exit `0` with `already initialized: <path>`: idempotent no-op — the store was already healthy. Report that no action was needed.
   - Exit `3`: the `.gitignore` still does not cover the target (your edit in step 2 may not match, or was skipped) — relay the message and stop; do not retry with a different path.
   - Exit `6`: reviewer-role refusal, or an unresolved fleet identity inside tmux — relay the single stderr line verbatim and stop; this is expected behavior in a `*-reviewer` pane, not a bug.
   - Exit `4`: a store-integrity problem (e.g. an unsafe pre-existing path) — relay the message verbatim and stop.

Never invoke `memory-write.sh bootstrap` directly from this command — always go through `init.sh` so the gitignore-coverage gate is enforced.

$ARGUMENTS
