---
description: List trusted session-chat dispatch message files
argument-hint: "[--older-than 7d] [--sender name] [--recipient name]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-messages.sh" $ARGUMENTS
   ```

3. Present the tab-separated output as file, age in seconds, size in bytes, sender, and recipient.
4. This command is read-only.
