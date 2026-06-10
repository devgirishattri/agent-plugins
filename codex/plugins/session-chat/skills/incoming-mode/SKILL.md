---
name: incoming-mode
description: "Show session-chat incoming message mode, explain notify/assist/auto/off, or print export guidance for changing it."
---

# Incoming Mode

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/0.14.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-chat"
```

Run:

```bash
bash "$PLUGIN_ROOT/scripts/incoming-mode.sh" "<optional-mode>"
```

With no mode, report the current `SESSION_CHAT_INCOMING_MODE` and explain all modes. With a mode, return the printed `export SESSION_CHAT_INCOMING_MODE=<mode>` command and explain that the user must run it in the shell that starts Codex, then restart or reload the session. Do not claim this command mutates the current parent Codex environment.
