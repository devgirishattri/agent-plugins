---
description: Dry-run or delete trusted session-chat dispatch message files
argument-hint: "[--older-than 7d] [--sender name] [--recipient name] [--apply]"
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
   bash "$PLUGIN_ROOT/scripts/clean-messages.sh" <confirmed filters> --apply
   ```

5. If the original arguments did not contain `--apply`, stop after the preview,
   tell the user how to request deletion, and never add `--apply` yourself.
6. Never infer confirmation from the original `--apply`. Report cancellation or the deleted count and bytes.
7. If a duration is invalid, use values like `7d`, `12h`, `30m`, or `60s`.
