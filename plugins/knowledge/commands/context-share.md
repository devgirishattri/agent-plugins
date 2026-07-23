---
description: Share a session context summary with another named session
argument-hint: <session-name> [snapshot-name]
allowed-tools: Bash(bash:*)
---

## Instructions

1. Parse $ARGUMENTS: first word is the target session, second word (optional) is the snapshot name.
   - If no snapshot name given, derive from current directory name and
     normalize it to canonical `snake_case`
     (`^[a-z0-9]+(_[a-z0-9]+)*$`).
   - If a snapshot name is supplied and it is not canonical `snake_case`,
     reject it instead of invoking the helper.

2. Run the share script. `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started (never export or derive it here). Sharing performs nested session-chat/tmux transport: if the runtime sandboxes tmux/socket access, request scoped escalation/approval for this exact installed helper on the first attempt — the command stays one literal Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/share-context.sh" "<session-name>" "<snapshot-name>"
   ```
   A failed share is transport-only (no store state changes), so fixing the transport cause and re-running the same command is safe. If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request that this pane/session be relaunched with the correct environment instead of deriving another context store.

3. Relay the script's output as-is — it reports the store path and which transport was used (session-chat's durable inbox when installed, otherwise the builtin fallback). The recipient can load it with `/context-load <snapshot-name>` **only if they share the same store / repo** (sharing notifies; it does not copy the file).
4. If the snapshot doesn't exist, suggest running `/context-generate` first.
