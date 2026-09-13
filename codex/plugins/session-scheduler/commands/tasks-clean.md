---
description: Dry-run or delete scheduler task records of any status, optionally narrowed by --status
argument-hint: "[--older-than 7d] [--status STATUS] [--apply]"
---

## Instructions

1. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Do not infer it from cwd or hardcode a cache version.

2. `SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Every invocation below must be exactly one
   Bash segment, with no `export` beforehand, no `env` or variable-assignment
   prefix, and no other command chained, piped, redirected, or substituted
   around it. If the script reports the variable is not set, stop and request
   that this pane be relaunched with the correct environment instead of
   deriving another ledger.
3. Always run a dry-run with `--apply` stripped from `$ARGUMENTS` and show the
   exact task candidates and the separate `Orphans:` list. If both lists are
   empty, report that and stop.
4. If (and only if) `--apply` was in the user's original arguments, ask for
   explicit Yes/No confirmation using structured `request_user_input` when
   available in the current mode, or a direct blocking question otherwise.
   Put cancellation first and mark it recommended; default, missing, or
   ambiguous answers cancel.
5. Only after that explicit Yes, run:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/tasks-clean.sh" <confirmed filters> --apply
   ```

6. If the original arguments did not contain `--apply`, stop after the preview,
   tell the user how to request deletion, and never add `--apply` yourself.
7. Never infer confirmation from `--apply` in the original request. Report cancellation or the deleted count.

`--older-than N` means N days for a bare integer; `d`, `h`, `m`, and `s` suffixes specify units explicitly. Value-taking flags require a value. Selection covers all statuses unless narrowed by `--status`.

Tasks referenced in `depends_on` by any task outside the deletion set are kept and reported as `kept <id> (referenced by <ids>)`. For each deletable task, remove only `tasks/<id>.json`, `prompts/<id>.md`, `prompts/<id>-review.md`, `prompts/<id>-ack-done.md`, `prompts/<id>-ack-blocked.md`, `prompts/<id>-ack-review.md`, `handoffs/<id>/`, and `locks/<id>.lock/`. Never use a task-prefix glob: task `a` must not consume task `a-b` artifacts.

The same run and age threshold also select orphan handoff directories and known-suffix prompt files whose task JSON is absent, using their mtime. Dry-run lists them under `Orphans:`; `--apply` removes them. Cleanup is explicit, not automatic.
