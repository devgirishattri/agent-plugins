---
name: incoming-mode
description: "Show session-chat incoming message mode, explain notify/assist/auto/off, or print export guidance for changing it."
---

# Incoming Mode

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/incoming-mode.sh" "<optional-mode>"
```

With no mode, report the current `SESSION_CHAT_INCOMING_MODE` and explain all modes. With a mode, return the printed `export SESSION_CHAT_INCOMING_MODE=<mode>` command and explain that the user must run it in the shell that starts Codex, then restart or reload the session. Do not claim this command mutates the current parent Codex environment.
