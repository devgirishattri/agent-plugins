---
name: tasks-clean
description: "Dry-run or delete old scheduler task records."
---

# Tasks Clean

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_SCHEDULER_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Every invocation below must be exactly one
Bash segment, with no `export` beforehand, no `env` or variable-assignment
prefix, and no other command chained, piped, redirected, or substituted around
it. If the script reports the variable is not set, stop and request a pane
relaunch with the correct environment instead of deriving another ledger.

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
bash "<PLUGIN_ROOT>/scripts/tasks-clean.sh" <confirmed args including --apply>
```

Never honor `--apply` without confirmation. Report cancellation or the deleted count.
