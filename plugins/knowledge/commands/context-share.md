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
   - A failed share is transport-only and changes no store state. Fix the transport cause. Then re-run the same command.
   - If the script reports `SESSION_CONTEXT_HOME` is not set, stop. Ask the user to relaunch this pane or session with the correct environment. Do not derive another context store.

3. Relay the script's output as-is. It reports the store path and the transport used: session-chat's durable inbox when installed, otherwise the builtin fallback. Tell the user that the recipient can load the snapshot with `/context-load <snapshot-name>` **only if the recipient shares the same store or repo**. Sharing notifies. It does not copy the file.
4. If the snapshot does not exist, suggest `/context-generate` first.
