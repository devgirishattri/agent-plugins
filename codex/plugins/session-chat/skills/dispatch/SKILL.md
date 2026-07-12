---
name: dispatch
description: "Dispatch a task prompt to another named tmux pane through session-chat. Use when the user asks to assign work, dispatch a task, or send a tracked task to another Codex session."
---

# Dispatch

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Use that absolute path; never
infer it from cwd or hardcode a marketplace cache version.

Parse the first argument as the target pane name and the rest as the task prompt. If either is missing, tell the user:

```text
Usage: $session-chat:dispatch <pane-name> <task prompt>
```

If this is a response to an incoming session-chat message or dispatch, use
`$session-chat:reply <pane> <incoming-id> <message>` instead so reply
correlation cannot be omitted.

Stage the prompt as data, never as shell source:

1. Run `mktemp -d "${TMPDIR:-/tmp}/session-chat-dispatch.XXXXXX"` in a
   separate shell call and capture the returned directory. This command contains
   no task text.
2. Use the `apply_patch` tool to add `<returned-directory>/prompt.md` with the
   verbatim prompt body. Never embed prompt text in a shell heredoc, `echo`,
   `printf`, command substitution, or an interpreter `-c` string: a delimiter
   line or shell metacharacters must remain inert task content.
3. Run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/dispatch-to-session.sh" [--priority high] [--ttl <minutes>] [--reply-to <incoming-id>] "<target>" "<returned-directory>/prompt.md"
   ```

4. Use `apply_patch` to delete the temporary prompt file, then remove its empty
   temporary directory. If no data-safe file-writing tool is available, stop
   and ask the user for an existing prompt-file path; never fall back to shell
   interpolation.

If tmux is not active, explain that dispatch requires running Codex inside tmux.
If the target is not found, suggest `$session-chat:panes`. If this pane has no name, suggest `$session-chat:whoami <name>`.
Relay the script's `Dispatched task ...` or `Queued dispatch ...` result accurately. For either successful result, mention that the recipient must use `SESSION_CHAT_INCOMING_MODE=auto` or `assist` to read and act on the task; default `notify` only reports that a dispatch arrived.
If the output reports multiple panes named the same target, tell the user to rename one pane with `$session-chat:whoami <name>`.
If a live timeout is followed by `Queued dispatch ...`, report durable queued success and do not retry. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` only when immediate live delivery matters. Retry only a hard failure that did not queue, after fixing its cause.
