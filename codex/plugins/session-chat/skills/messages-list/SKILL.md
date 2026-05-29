---
name: messages-list
description: "List trusted session-chat dispatch message files with age, size, sender, and recipient filters."
---

# Messages List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.12.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/list-messages.sh" <args>
```

Supported args: `--older-than 7d`, `--sender <name>`, and `--recipient <name>`. This command is read-only. Present the tab-separated output as file, age in seconds, size in bytes, sender, and recipient.
