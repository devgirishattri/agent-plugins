---
name: messages-clean
description: "Dry-run or delete trusted session-chat dispatch message files by age, sender, or recipient."
---

# Messages Clean

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.13.3}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/clean-messages.sh" <args>
```

Supported args: `--older-than 7d`, `--sender <name>`, `--recipient <name>`, and `--apply`. Without `--apply`, this is a dry run and must not delete files. With `--apply`, report the deleted count and total bytes.
