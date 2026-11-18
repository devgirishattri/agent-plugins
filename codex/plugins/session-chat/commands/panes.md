---
description: List named tmux panes in the current tmux session, or all sessions
argument-hint: "[all]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/list-panes.sh"
   ```

3. With empty `$ARGUMENTS`, use the command as shown to list named panes in this tmux session. If the user supplied `all`, append the literal argument `all` to list named panes across every tmux session.
4. Present the tab-separated output as a markdown table:

   ```text
   | Name | Pane | Command | Location |
   ```

Rules:
- If the script returns non-zero, relay its error; never interpret blank output
  as an empty pane list. If a sandbox denied the tmux socket, rerun the whole
  script escalated/approved.
- Only a successful empty result means no named panes were found.
- Suggest `$session-chat:whoami <name>` to name the current pane.
- Suggest `$session-chat:send <name> <message>` to message a pane.
- Mention `$session-chat:panes all` only when the user needs every tmux session.
