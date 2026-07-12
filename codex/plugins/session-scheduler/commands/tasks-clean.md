---
description: Dry-run or delete scheduler task records of any status, optionally narrowed by --status
argument-hint: "[--older-than 7d] [--status STATUS] [--apply]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Always run a dry-run with `--apply` stripped from `$ARGUMENTS` and show the
   exact candidates. If it lists zero candidates, report that and stop.
3. If (and only if) `--apply` was in the user's original arguments, ask for
   explicit Yes/No confirmation using structured `request_user_input` when
   available in the current mode, or a direct blocking question otherwise.
   Put cancellation first and mark it recommended; default, missing, or
   ambiguous answers cancel.
4. Only after that explicit Yes, run:

   ```bash
   export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
   bash "$PLUGIN_ROOT/scripts/tasks-clean.sh" <confirmed filters> --apply
   ```

5. If the original arguments did not contain `--apply`, stop after the preview,
   tell the user how to request deletion, and never add `--apply` yourself.
6. Never infer confirmation from `--apply` in the original request. Report cancellation or the deleted count.
