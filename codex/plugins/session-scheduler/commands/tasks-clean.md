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
   exact candidates. If it lists zero candidates, report that and stop.
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
