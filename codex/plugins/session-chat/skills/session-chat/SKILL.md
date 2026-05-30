---
name: session-chat
description: "Coordinate Codex sessions over tmux with guidance for choosing send vs dispatch, recipient setup, reliability tunables, and common failure modes."
---

# Session Chat

Use this skill when the user asks how session-chat works, which command to use, how to configure receiving panes, or how to troubleshoot delivery.

## Choosing A Command

| Use case | Command | Notes |
| --- | --- | --- |
| Short status, acknowledgement, or question | `$session-chat:send <pane> <message>` | Single line only, up to `SESSION_CHAT_SEND_MAX_LEN` characters. Default max is 1024. |
| Multi-line task, code, logs, or detailed report | `$session-chat:dispatch <pane> <task>` | Writes the full prompt to a trusted message file and sends a notification. |
| Work that should be tracked and resumed from a file | `$session-chat:dispatch <pane> <task>` | Receiver sees the file path, line count, and message id. |
| Unsure whether content might contain newlines or shell-sensitive text | `$session-chat:dispatch <pane> <task>` | Avoids `/send` payload limits and inline quoting ambiguity. |

## Recipient Prerequisites

- The recipient must be running inside tmux.
- The recipient pane must have a unique name from `$session-chat:whoami <name>`.
- Use `$session-chat:panes` to inspect the current tmux session, or `$session-chat:panes all` when the target may be in another tmux session.
- In Codex, the plugin `hooks.json` runs on `SessionStart` and `UserPromptSubmit` to load tmux styling, auto-name unnamed panes when possible, and surface incoming messages according to `SESSION_CHAT_INCOMING_MODE`.
- For orchestration, the recipient should set `SESSION_CHAT_INCOMING_MODE=auto` or `SESSION_CHAT_INCOMING_MODE=assist`.
- The default `SESSION_CHAT_INCOMING_MODE=notify` treats incoming content as untrusted, forbids reading dispatch files, and asks the local user before acting. Dispatches can appear to no-op in this mode.

## Recipient Format

Direct messages are submitted as:

```text
[from:<sender> pane:<pane-id> id:<id>] <message>
```

Dispatch notifications are submitted as:

```text
[from:<sender> pane:<pane-id> msg:<message-file> id:<id>] dispatch (<line-count> lines) — read msg file for full task
```

The dispatch notification intentionally has no task preview. The receiver must read the referenced file only when its incoming mode and local user policy allow it.

## Reliability Contract

Session-chat takes a per-target lock before writing to a pane, sends text with `tmux send-keys -l`, verifies a marker in `capture-pane -S -200`, then sends Enter only after verification succeeds. If verification times out, it sends `C-u` to clear any partial paste, backs off, and retries before returning failure.

Codex TUI redraws, wrapping, approval prompts, and active command output can still hide typed markers from `capture-pane`. If a valid send reports that it did not land, retry after the target is idle or raise the verification timeout.

For durable fallback, the sender writes the queue row and dispatch file into the recipient runtime's message directory. Codex recipients use `${CODEX_HOME:-~/.codex}/messages`; Claude recipients use `${CLAUDE_HOME:-~/.claude}/messages`. Queue operations lock under that recipient message directory so mixed Codex/Claude fallback does not depend on both runtimes sharing the same `TMPDIR`.

## Tunables

- `SESSION_CHAT_VERIFY_TIMEOUT_MS`: marker verification timeout in milliseconds. Default: `4000`.
- `SESSION_CHAT_SETTLE_MS`: delay after a successful Enter. Default: `300`.
- `SESSION_CHAT_SEND_MAX_LEN`: maximum `/send` payload length. Default: `1024`.
- `SESSION_CHAT_SKIP_VERIFY`: set to `1` to skip marker verification.
- `SESSION_CHAT_INCOMING_MODE`: receiver behavior. Values: `notify`, `assist`, `auto`, `off`. Default: `notify`.
- `SESSION_CHAT_LOCK_TIMEOUT_MS`: how long a sender waits for a per-pane send lock. Default: auto-derived from the send budget (~4× one send) and reset whenever the lock holder changes, so fan-in to one pane queues instead of failing. When set explicitly, it is a hard cap.
- `SESSION_CHAT_SEND_RETRIES`: retry count after verify timeouts. Default: `2`.
- `SESSION_CHAT_RETRY_BACKOFF_MS`: linear retry backoff base in milliseconds. Default: `200`.
- `SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS`: how long a pre-live durable queue row waits before hook recovery if the sender dies mid-send. Default: auto-derived from lock plus send budget; known live-send failures mark the row ready immediately.
- `SESSION_CHAT_RECENT_ID_TTL_MS`: how long surfaced message ids suppress duplicate live arrivals. Default: `600000`.

## Common Failures

- `did not land within Xms after N attempts`: target was busy through all retries. The message is **not lost** — it's in the recipient's durable inbox (`~/.codex/messages/queue/<name>.tsv` for Codex, `~/.claude/messages/queue/<name>.tsv` for Claude) and surfaces after the failed live attempt or recovery grace (the sender reports "Queued …"). To land more sends live, raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` or `SESSION_CHAT_SEND_RETRIES`.
- `timed out waiting for send lock`: rare now that the unset lock timeout auto-sizes to the send budget and resets on holder change. If `SESSION_CHAT_LOCK_TIMEOUT_MS` is set, that value is treated as an absolute cap.
- `Multiple panes named X`: rename one pane with `$session-chat:whoami <name>` in that pane.
- `No pane named X`: run `$session-chat:panes all` and confirm the recipient has run `$session-chat:whoami <name>`.
- `/send only supports single-line messages`: use `$session-chat:dispatch`.
- `/send payload exceeds ... characters`: use `$session-chat:dispatch`.

## Incoming Mode

Use `$session-chat:incoming-mode` to show the current receiver mode and explain `notify`, `assist`, `auto`, and `off`. The `UserPromptSubmit` hook reads this value when incoming tmux messages are submitted to Codex, then emits model-visible `hookSpecificOutput.additionalContext` capped at 10000 characters. Use `$session-chat:incoming-mode auto` or another mode to print an `export SESSION_CHAT_INCOMING_MODE=<mode>` command. Run that export in the shell that starts Codex, then restart or reload the session; a child script cannot mutate the parent Codex environment.

## Message Files

Use `$session-chat:messages-list` to inspect trusted dispatch message files in `$CODEX_HOME/messages`. Use `$session-chat:messages-clean` to preview cleanup by age, sender, or recipient. Cleanup is a dry run by default; add `--apply` to delete matching files.

## Reinstalling Source Changes

This source tree may be newer than the running Codex plugin cache. To make the running registry pick up this version after publishing or local marketplace refresh, run:

```bash
codex plugin marketplace upgrade girishattri-codex-plugins
```

Then restart Codex or use `/reload-plugins` if the runtime supports it. To verify the cached version, inspect `$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-chat/`; if the session still shows an older cached path such as `session-chat/0.10.1`, reload before testing new commands.
