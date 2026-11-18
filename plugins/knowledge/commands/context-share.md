---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
allowed-tools: Bash(bash:*)
---

## Instructions

1. Parse $ARGUMENTS. The first word is the target session. The second word (optional) is the snapshot name.
   - If no snapshot name is given, derive one from the current directory name. Normalize it to canonical `snake_case` (`^[a-z0-9]+(_[a-z0-9]+)*$`).
   - If a snapshot name is given and it is not canonical `snake_case`, reject it. Do not invoke the helper.

2. Run the share script. `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. Never export or derive it here.
   - Sharing performs nested session-chat/tmux transport. If the runtime sandboxes tmux or socket access, request scoped escalation or approval for this exact installed helper on the first attempt.
   - The command stays one literal Bash segment. Use no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
   ```
   - Sharing preserves snapshot content. Store initialization may create directories or harden permissions. A transport failure can leave the notification queued or staged in the recipient's input. Check `/session-chat:pane-health` for the recipient. If delivery is uncertain, confirm receipt before resending. Retry only after verifying that nothing was staged, queued or delivered.
   - If the script reports `SESSION_CONTEXT_HOME` is not set, stop. Ask the user to relaunch this pane or session with the correct environment. Do not derive another context store.

3. Relay the script's output as-is. On success it reports the store and transport. The recipient can load the snapshot with `/knowledge:context-load <snapshot-name>` only if both panes inherit the same context store. Sharing sends a notification and leaves the snapshot in that store.
4. If the snapshot does not exist, suggest `/context-generate` first.
