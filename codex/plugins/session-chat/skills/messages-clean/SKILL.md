---
name: messages-clean
description: "Dry-run or delete trusted session-chat dispatch message files by age, sender, or recipient."
---

# Messages Clean

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Always preview first, stripping `--apply` from the script invocation and showing
the exact candidates. If the preview has no candidates, report that and stop.

If (and only if) `--apply` was in the user's original arguments, ask for
explicit confirmation. Use structured `request_user_input` when available;
otherwise ask a direct blocking Yes/No question. Put cancellation first and
mark it recommended. Missing or ambiguous answers cancel.

When the original arguments did not contain `--apply`, stop after the preview
and tell the user to invoke the skill again with `--apply` if they want to
delete. Do not prompt and never add `--apply` yourself.

Only after explicit confirmation, run:

```bash
bash "$PLUGIN_ROOT/scripts/clean-messages.sh" <confirmed filters including --apply>
```

Supported filters are `--older-than`, `--sender`, and `--recipient`. Never honor
`--apply` without the separate confirmation. Report cancellation or the
deleted count and bytes.
