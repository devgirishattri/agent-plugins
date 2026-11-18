---
name: incoming-mode
description: "Show session-chat incoming message mode, explain notify/assist/auto/off, or print export guidance for changing it."
---

# Incoming Mode

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Use the helper with no arguments to show the current mode. To explain a change, append exactly one valid mode (`notify`, `assist`, `auto`, or `off`).

```bash
bash "$PLUGIN_ROOT/scripts/incoming-mode.sh"
```

With no mode, report the current value and explain the four modes. With a mode, relay the printed export. Apply the printed `export SESSION_CHAT_INCOMING_MODE=<mode>` in the recipient's launcher or parent shell, then relaunch the agent so it inherits that value.
