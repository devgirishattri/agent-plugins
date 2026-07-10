---
name: messages-list
description: "List trusted session-chat dispatch message files with age, size, sender, and recipient filters."
---

# Messages List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/list-messages.sh" <args>
```

Supported args: `--older-than 7d`, `--sender <name>`, and `--recipient <name>`. This command is read-only. Present the tab-separated output as file, age in seconds, size in bytes, sender, and recipient.
