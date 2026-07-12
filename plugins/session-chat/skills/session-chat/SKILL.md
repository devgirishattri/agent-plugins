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

1. The recipient has a registered pane name (via `/whoami <name>`, or auto-named at SessionStart from the session's custom title).
2. The recipient's `SESSION_CHAT_INCOMING_MODE` is set to one of:
   - `auto` — recipient may read the dispatch file and act without confirming.
   - `assist` — recipient summarizes the incoming message and asks the local user before acting.
   - `notify` (default) — recipient is told a message arrived but is **forbidden** from reading the dispatch file. Orchestration silently no-ops in this mode.
   - `off` — hook does nothing.

If you are orchestrating peer agents, set `SESSION_CHAT_INCOMING_MODE=auto` in the recipient's environment **before** they start their session, or your dispatches will land but never be acted on.

## Message format the recipient sees

Both operations produce a single line in the recipient's prompt buffer:

- `/send` →  `[from:NAME pane:%N id:HEX8] <message text> [id:HEX8]`
- `/dispatch` → `[from:NAME pane:%N msg:/path/to/file.md id:HEX8] dispatch (N lines) — read msg file for full task id:HEX8`

The `id:` field is a unique verification marker and is repeated at the tail so it remains visible in TUIs that show the end of long input lines. The dispatch line **does not include a preview** of the message body — the recipient must read `$msg_file`.

## Reliability contract

`send_text` (used by both ops) does the following before returning success:

1. Pastes the literal message into the recipient pane (no Enter yet).
2. Polls `tmux capture-pane` (last 200 lines) for the unique `id:` marker or a newly-created `[Pasted text #N]` placeholder, up to `SESSION_CHAT_VERIFY_TIMEOUT_MS` (default 4000ms).
3. On success: presses Enter, waits `SESSION_CHAT_SETTLE_MS` (default 300ms), returns 0.
4. On timeout: sends a line-edit clear sequence (`C-e C-u`, `C-a C-k`, `C-e C-u`) to clear the partial paste from the recipient's prompt, returns 1.

This means a failed send **does not leave junk in the recipient's prompt**. If you see "did not land within Xms," the recipient was likely busy in an approval gate or rendering a long TUI frame.

## Durable delivery & orchestrator fan-in

Every `/send` and `/dispatch` is **written to the recipient's durable inbox before the live paste** — under the **recipient runtime's** messages dir: `~/.claude/messages/queue/<recipient>.tsv` for a Claude pane, `~/.codex/messages/queue/<recipient>.tsv` for a Codex pane (each runtime only drains its own dir). So delivery no longer depends on the paste landing while the recipient is busy:

- **Live paste lands** → the message appears in the recipient's prompt now, and the durable copy is removed (no duplicate).
- **Live paste fails** (recipient mid-generation / in an approval gate) → the wrapper prints **"Queued … will arrive on their next turn"** and **exits 0** (the internal send/dispatch function signals the queued path with return code 3; the public `/send` and `/dispatch` wrappers translate that to a normal success exit). The recipient's `UserPromptSubmit` hook drains the inbox on its **next** turn — and the `Stop` hook drains it when the recipient **finishes its current turn**, so even a pane that never submits another prompt surfaces queued messages as soon as it stops working. Nothing is lost. Dedup across the two paths is by the `id:` marker.

This specifically fixes the **orchestrator-misses-acks** case: when several executors/reviewers ack a busy orchestrator at once, their sends queue on the orchestrator's per-target lock instead of erroring, and any that can't paste live are recovered from the inbox. The send lock now **waits for the full per-send budget and resets whenever the queue moves**, so fan-in to one pane no longer trips "could not acquire send-lock". For an idle recipient the paste still lands immediately; the inbox is the safety net for busy ones.

If a recipient pane sits at an idle prompt (no turn in progress, no prompt coming), neither hook fires; raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` so the live paste itself succeeds in that case.

## Reply correlation

Every `/send` and `/dispatch` has a unique `id:HEX8`. To reply, use **`/reply <pane> <message-id> <message>`** — it prepends the `[re:<id>]` correlation token for you (exactly once) and auto-picks `/send` for a short reply or `/dispatch` for a long/multiline one, so the original sender's `/check-replies` matches it. Do **not** hand-type `[re:<id>]` tokens; pass the `id:<hex>` from the message you're answering and let `/reply` add it. (The raw transports also accept `--reply-to <id>` if you script them directly.) When you ask a peer a question and expect an answer, tell it to `/reply` with your message id; then poll `/check-replies --pending` instead of re-pinging panes that already answered.

## Priorities and TTL

Both `/send` and `/dispatch` (and `/broadcast`) accept `--priority high` and `--ttl <minutes>`:

- `--priority high` — if the message ends up queued (recipient busy), it surfaces **before** normal-priority messages when the recipient's hook drains the inbox. Live delivery is unaffected (it is already immediate). Use for abort signals and gating decisions, not routine status.
- `--ttl <minutes>` — if the message is still sitting in the queue after this window, it is **dropped unsurfaced**. Use for time-sensitive pings whose answer is useless later (e.g. "status now"); never for task dispatches that must eventually run.

## Quoting and shell safety

The wrapper command (`/send`, `/dispatch`) passes the message via shell argv. When constructing the bash invocation:

- Always wrap the message in double quotes.
- Escape embedded `"`, `$`, and backticks, or use single quotes if the payload has none of those.
- Multi-line payloads are not allowed for `/send` — write the full prompt to a temp file and use `dispatch-to-session.sh <target> <file>` (which is what `/dispatch` does internally).

## Tunables

| Env var | Default | Purpose |
|---|---|---|
| `SESSION_CHAT_VERIFY_TIMEOUT_MS` | 4000 | Max wait per attempt for paste to land in recipient pane. |
| `SESSION_CHAT_SETTLE_MS` | 300 | Settle window after Enter so back-to-back sends don't race. |
| `SESSION_CHAT_SEND_MAX_LEN` | 1024 | Max length for `/send` payload before forcing `/dispatch`. |
| `SESSION_CHAT_SEND_RETRIES` | 2 | Retry count after a verify timeout (total attempts = retries + 1). |
| `SESSION_CHAT_RETRY_BACKOFF_MS` | 200 | Linear backoff base between retries (200ms, 400ms, …). |
| `SESSION_CHAT_LOCK_TIMEOUT_MS` | derived (~4× per-send budget) | Max wait for the per-target send lock. When unset, auto-sized to the send budget and reset whenever the lock holder changes, so fan-in to one pane queues instead of failing. When set explicitly, it is an **absolute cap** (no reset) so total wait never exceeds it. |
| `SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS` | derived (lock + send budget + 1000ms) | How long a freshly-queued durable row waits before the recipient hook may surface it, giving an in-flight live paste time to win. A known-failed live send marks its row ready immediately. |
| `SESSION_CHAT_RECENT_ID_TTL_MS` | 600000 | How long a surfaced message `id` is remembered so a queued entry and its later live paste never both surface (cross-turn dedup). |
| `SESSION_CHAT_ARCHIVE_RETENTION_DAYS` | 30 | How long daily message-archive files are kept for `/message-search`. |
| `SESSION_CHAT_SKIP_VERIFY` | 0 | Set `1` to skip receipt verification (not recommended). |
| `SESSION_CHAT_INCOMING_MODE` | notify | Recipient-side: `auto` / `assist` / `notify` / `off`. Use `/incoming-mode` to inspect or generate the export line. |

## Helper commands

- `/broadcast [--all] [--match GLOB] <text>` — fan out one short message to every named pane (status pings, fleet-wide notices) instead of looping `/send` per pane.
- `/reply <pane> <message-id> <message>` — reply to a received message, auto-correlated: prepends the `[re:<id>]` token and picks `/send` (short) or `/dispatch` (long/multiline) for you. Use this instead of hand-typing `[re:<id>]`.
- `/check-replies [--pending] [--since MIN]` — which sent messages have a correlated reply (via `[re:<id>]` tokens) and which are still `unconfirmed`. This reflects reply **correlation only**, not the recipient's task progress or liveness — an `unconfirmed` row does not mean the pane is stuck; use `/pane-health` to check liveness.
- `/pane-health [name] [--all]` — liveness, inbox backlog, and lock state per named pane; catches dead/duplicate panes before sends time out against them.
- `/message-search <pattern> [--days N] [--peer NAME]` — search the message archive (every sent + surfaced incoming message, 200-char excerpts, 30-day retention via `SESSION_CHAT_ARCHIVE_RETENTION_DAYS`) plus full dispatch bodies.
- `/incoming-mode` — show or set `SESSION_CHAT_INCOMING_MODE` (prints an `export` line to `eval`).
- `/messages-list` — read-only inventory of dispatch files under `~/.claude/messages/`.
- `/messages-clean` — delete old dispatch files (dry-run by default; pass `--apply` to actually delete).

## Common failure modes

- **"pane 'X' is at a shell prompt"** — the recipient's agent exited; the message would have been executed by their shell. Restart the agent in that pane (set `SESSION_CHAT_ALLOW_SHELL_TARGET=1` only for deliberate shell targets, e.g. tests).
- **"This pane has no name"** — run `/whoami <name>` in the sending pane first.
- **"No pane named X"** — run `/panes all` to see registered names across tmux sessions; the recipient may not have run `/whoami`.
- **"Multiple panes named X"** — duplicate names exist; rename one with `/whoami` in that pane.
- **"did not land within Xms after N attempts"** — recipient busy through retries. The message is **not lost**: it's in the recipient's durable inbox and will surface on their next turn (the sender reports "Queued …"). To make more sends land *live*, raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` or `SESSION_CHAT_SEND_RETRIES`.
- **"could not acquire send-lock"** — another sender is targeting the same pane. Will resolve when they finish; raise `SESSION_CHAT_LOCK_TIMEOUT_MS` if you need to wait longer.
- **Dispatch lands but recipient never acts** — recipient is in `INCOMING_MODE=notify` (default). They were told not to read the file. Run `/incoming-mode auto` (or `assist`) in the recipient's shell.

## Reload after install

Plugin updates do not auto-reload running sessions. After `claude plugin update session-chat@girishattri-plugins`:

1. The new version is unpacked under `~/.claude/plugins/cache/girishattri-plugins/session-chat/<version>/`. Confirm with `ls ~/.claude/plugins/cache/girishattri-plugins/session-chat/`.
2. Reload in the current session: `/reload-plugins`.
3. Verify: `/panes` and `/incoming-mode` should respond from the new version. If `/incoming-mode` is "unknown command," reload didn't pick up the new commands — check the cache path.

For codex-side parity, run `codex plugin marketplace upgrade girishattri-plugins`, then start a **new Codex session** so the update is loaded. Its cache is under `~/.codex/plugins/cache/...`.
