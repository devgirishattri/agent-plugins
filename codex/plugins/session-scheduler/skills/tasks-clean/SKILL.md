---
name: tasks-clean
description: "Dry-run or delete old scheduler task records."
---

# Tasks Clean

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from the working directory or hardcode a marketplace cache version.

Always preview first, stripping `--apply` from the script invocation and showing
the exact candidates. If the preview has no candidates, report that and stop.

If (and only if) `--apply` was in the user's original arguments, ask for
explicit confirmation. Use structured `request_user_input` when available in
the current mode; otherwise ask a direct blocking Yes/No question. Put
cancellation first and mark it recommended. Default, missing, or ambiguous
answers cancel deletion.

When the original arguments did not contain `--apply`, stop after the preview
and tell the user to invoke the skill again with `--apply` if they want to
delete. Do not prompt and never add `--apply` yourself.

Only after an explicit Yes, run:

```bash
export SESSION_SCHEDULER_HOME="${SESSION_SCHEDULER_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/scheduler}"
bash "$PLUGIN_ROOT/scripts/tasks-clean.sh" <confirmed args including --apply>
```

Never honor `--apply` without confirmation. Report cancellation or the deleted count.
