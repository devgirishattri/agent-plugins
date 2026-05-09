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
- Use `$session-chat:panes` to confirm the target exists and that no duplicate names are present.
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

Session-chat sends text to the target pane with `tmux send-keys -l`, verifies a marker in `capture-pane -S -200`, then sends Enter only after verification succeeds. If verification times out, it sends `C-u` to clear any partial paste before returning failure.

Codex TUI redraws, wrapping, approval prompts, and active command output can still hide typed markers from `capture-pane`. If a valid send reports that it did not land, retry after the target is idle or raise the verification timeout.

## Tunables

- `SESSION_CHAT_VERIFY_TIMEOUT_MS`: marker verification timeout in milliseconds. Default: `2000`.
- `SESSION_CHAT_SETTLE_MS`: delay after a successful Enter. Default: `300`.
- `SESSION_CHAT_SEND_MAX_LEN`: maximum `/send` payload length. Default: `1024`.
- `SESSION_CHAT_SKIP_VERIFY`: set to `1` to skip marker verification.
- `SESSION_CHAT_INCOMING_MODE`: receiver behavior. Values: `notify`, `assist`, `auto`, `off`. Default: `notify`.

## Common Failures

- `did not land within Xms`: target may be busy, redrawing, or in an approval prompt. Retry when idle or increase `SESSION_CHAT_VERIFY_TIMEOUT_MS`.
- `Multiple panes named X`: rename one pane with `$session-chat:whoami <name>` in that pane.
- `No pane named X`: run `$session-chat:panes` and confirm the recipient has run `$session-chat:whoami <name>`.
- `/send only supports single-line messages`: use `$session-chat:dispatch`.
- `/send payload exceeds ... characters`: use `$session-chat:dispatch`.

## Reinstalling Source Changes

This source tree may be newer than the running Codex plugin cache. To make the running registry pick up this version after publishing or local marketplace refresh, run:

```bash
codex plugin marketplace upgrade girishattri-codex-plugins
```

Then restart or reload Codex if the session still shows an older cached path such as `session-chat/0.9.9`.
