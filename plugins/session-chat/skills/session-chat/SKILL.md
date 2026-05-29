---
name: session-chat
description: When and how to communicate with peer Claude/Codex sessions running in other tmux panes. Use this skill before invoking /send or /dispatch so you pick the right tool and the message actually lands.
---

# session-chat: peer-pane messaging

This plugin lets Claude/Codex sessions running in different tmux panes message each other. Two operations:

- `/send <name> <text>` — short, single-line message (status pings, acks, replies, "done", "ready").
- `/dispatch <name> <prompt>` — task hand-off; full prompt is written to a file and the recipient reads it.

## When to use which

| Use `/send` when… | Use `/dispatch` when… |
|---|---|
| Payload is one line | Payload is multi-line |
| Payload ≤ 1024 chars | Payload contains code, lists, structure |
| You want a quick reply / status | You want the peer to do work |
| No file content needs to round-trip | The task references files, plans, or instructions |

`/send` enforces the contract: it **refuses** to send when payload contains newlines or exceeds 1024 chars (configurable via `SESSION_CHAT_SEND_MAX_LEN`). If you hit that error, switch to `/dispatch`.

## Recipient prerequisites (read before dispatching)

A recipient pane will only receive messages if **both** are true:

1. The recipient ran `/whoami <name>` to register a name in their pane.
2. The recipient's `SESSION_CHAT_INCOMING_MODE` is set to one of:
   - `auto` — recipient may read the dispatch file and act without confirming.
   - `assist` — recipient summarizes the incoming message and asks the local user before acting.
   - `notify` (default) — recipient is told a message arrived but is **forbidden** from reading the dispatch file. Orchestration silently no-ops in this mode.
   - `off` — hook does nothing.

If you are orchestrating peer agents, set `SESSION_CHAT_INCOMING_MODE=auto` in the recipient's environment **before** they start their session, or your dispatches will land but never be acted on.

## Message format the recipient sees

Both operations produce a single line in the recipient's prompt buffer:

- `/send` →  `[from:NAME pane:%N id:HEX8] <message text>`
- `/dispatch` → `[from:NAME pane:%N msg:/path/to/file.md id:HEX8] dispatch (N lines) — read msg file for full task`

The `id:` field is a unique verification marker. The dispatch line **does not include a preview** of the message body — the recipient must read `$msg_file`.

## Reliability contract

`send_text` (used by both ops) does the following before returning success:

1. Pastes the literal message into the recipient pane (no Enter yet).
2. Polls `tmux capture-pane` (last 200 lines) for the unique `id:` marker, up to `SESSION_CHAT_VERIFY_TIMEOUT_MS` (default 2000ms).
3. On success: presses Enter, waits `SESSION_CHAT_SETTLE_MS` (default 300ms), returns 0.
4. On timeout: sends `C-u` to clear the partial paste from the recipient's prompt, returns 1 with an error.

This means a failed send **does not leave junk in the recipient's prompt**. If you see "did not land within Xms," the recipient was likely busy in an approval gate or rendering a long TUI frame. Retry after a short delay, or set `SESSION_CHAT_VERIFY_TIMEOUT_MS=5000` for slow recipients.

## Quoting and shell safety

The wrapper command (`/send`, `/dispatch`) passes the message via shell argv. When constructing the bash invocation:

- Always wrap the message in double quotes.
- Escape embedded `"`, `$`, and backticks, or use single quotes if the payload has none of those.
- Multi-line payloads are not allowed for `/send` — write the full prompt to a temp file and use `dispatch-to-session.sh <target> <file>` (which is what `/dispatch` does internally).

## Tunables

| Env var | Default | Purpose |
|---|---|---|
| `SESSION_CHAT_VERIFY_TIMEOUT_MS` | 2000 | Max wait per attempt for paste to land in recipient pane. |
| `SESSION_CHAT_SETTLE_MS` | 300 | Settle window after Enter so back-to-back sends don't race. |
| `SESSION_CHAT_SEND_MAX_LEN` | 1024 | Max length for `/send` payload before forcing `/dispatch`. |
| `SESSION_CHAT_SEND_RETRIES` | 2 | Retry count after a verify timeout (total attempts = retries + 1). |
| `SESSION_CHAT_RETRY_BACKOFF_MS` | 200 | Linear backoff base between retries (200ms, 400ms, …). |
| `SESSION_CHAT_LOCK_TIMEOUT_MS` | 3000 | Max wait for the per-target send lock; concurrent senders to the same pane queue. |
| `SESSION_CHAT_SKIP_VERIFY` | 0 | Set `1` to skip receipt verification (not recommended). |
| `SESSION_CHAT_INCOMING_MODE` | notify | Recipient-side: `auto` / `assist` / `notify` / `off`. Use `/incoming-mode` to inspect or generate the export line. |

## Helper commands

- `/incoming-mode` — show or set `SESSION_CHAT_INCOMING_MODE` (prints an `export` line to `eval`).
- `/messages-list` — read-only inventory of dispatch files under `~/.claude/messages/`.
- `/messages-clean` — delete old dispatch files (dry-run by default; pass `--apply` to actually delete).

## Common failure modes

- **"This pane has no name"** — run `/whoami <name>` in the sending pane first.
- **"No pane named X"** — run `/panes all` to see registered names across tmux sessions; the recipient may not have run `/whoami`.
- **"Multiple panes named X"** — duplicate names exist; rename one with `/whoami` in that pane.
- **"did not land within Xms after N attempts"** — recipient busy through retries. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` or `SESSION_CHAT_SEND_RETRIES`, or send when the recipient is idle.
- **"could not acquire send-lock"** — another sender is targeting the same pane. Will resolve when they finish; raise `SESSION_CHAT_LOCK_TIMEOUT_MS` if you need to wait longer.
- **Dispatch lands but recipient never acts** — recipient is in `INCOMING_MODE=notify` (default). They were told not to read the file. Run `/incoming-mode auto` (or `assist`) in the recipient's shell.

## Reload after install

Plugin updates do not auto-reload running sessions. After `claude plugin update session-chat@girishattri-plugins`:

1. The new version is unpacked under `~/.claude/plugins/cache/girishattri-plugins/session-chat/<version>/`. Confirm with `ls ~/.claude/plugins/cache/girishattri-plugins/session-chat/`.
2. Reload in the current session: `/reload-plugins`.
3. Verify: `/panes` and `/incoming-mode` should respond from the new version. If `/incoming-mode` is "unknown command," reload didn't pick up the new commands — check the cache path.

For codex-side parity, the equivalent codex install + reload commands apply (codex caches under `~/.codex/plugins/cache/...`).
