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

`/send` enforces the contract. It **refuses** to send when the payload contains newlines or exceeds 1024 chars (configurable via `SESSION_CHAT_SEND_MAX_LEN`). If you hit that error, switch to `/dispatch`.

## Recipient prerequisites (read before dispatching)

A recipient pane receives messages only if **both** conditions are true:

1. The recipient has a registered pane name. Register it with `/whoami <name>`, or rely on auto-naming at SessionStart from the session's custom title.
2. The recipient's `SESSION_CHAT_INCOMING_MODE` is set to one of:
   - `auto` — the recipient is permitted to read the dispatch file and act without confirming.
   - `assist` — the recipient summarizes the incoming message and asks the local user before acting.
   - `notify` (default) — the recipient is told a message arrived but is **forbidden** from reading the dispatch file. Orchestration silently no-ops in this mode.
   - `off` — hook does nothing.

When you orchestrate peer agents, set `SESSION_CHAT_INCOMING_MODE=auto` in the recipient's environment **before** they start their session. Otherwise your dispatches land but are never acted on.

## Message format the recipient sees

Both operations produce a single line in the recipient's prompt buffer:

- `/send` →  `[from:NAME pane:%N id:HEX8] <message text> [id:HEX8]`
- `/dispatch` → `[from:NAME pane:%N msg:/path/to/file.md id:HEX8] dispatch (N lines) — read msg file for full task id:HEX8`

The `id:` field is a unique verification marker. It is repeated at the tail so it stays visible in TUIs that show the end of long input lines. The dispatch line **does not include a preview** of the message body. The recipient must read `$msg_file`.

## Reliability contract

`send_text` (used by both ops) does the following before returning success:

1. Pastes the literal message into the recipient pane (no Enter yet).
2. Polls `tmux capture-pane` (last 200 lines) for the unique `id:` marker or a newly-created `[Pasted text #N]` placeholder, up to `SESSION_CHAT_VERIFY_TIMEOUT_MS` (default 4000ms).
3. On success: presses Enter, waits `SESSION_CHAT_SETTLE_MS` (default 300ms), returns 0.
4. On timeout: sends a line-edit clear sequence (`C-e C-u`, `C-a C-k`, `C-e C-u`) to clear the partial paste from the recipient's prompt, returns 1.

A failed send **does not leave junk in the recipient's prompt**. If you see "did not land within Xms," the recipient was likely busy in an approval gate or rendering a long TUI frame.

## Durable delivery & orchestrator fan-in

The sender writes every `/send` and `/dispatch` to the recipient's durable inbox **before** the live paste. The inbox sits under the **recipient runtime's** messages dir:

- Claude pane: `${CLAUDE_HOME:-~/.claude}/messages/queue/<recipient>.tsv`
- Codex pane: `${CODEX_HOME:-~/.codex}/messages/queue/<recipient>.tsv`

Each runtime drains only its own dir. An exported `SESSION_CHAT_TARGET_MESSAGES_DIR` takes precedence over both. When you set it in every participating pane, it becomes the shared sender and receiver mailbox root instead. So delivery does not depend on the paste landing while the recipient is busy.

| Live paste | Wrapper output | Exit code | Recipient sees the message |
|---|---|---|---|
| Lands | The message appears in the recipient's prompt now. The durable copy is removed (no duplicate). | 0 | Now |
| Fails (recipient mid-generation or in an approval gate) | **"Queued … will arrive on their next turn"** | **0** | On the next turn, or when the current turn ends |

The internal send/dispatch function returns code 3 for the queued path. At the boundary, the public `/send` and `/dispatch` wrappers translate that to a normal success exit.

A queued message surfaces through two hooks:

- The recipient's `UserPromptSubmit` hook drains the inbox on its **next** turn.
- The `Stop` hook drains it when the recipient **finishes its current turn**. So even a pane that never submits another prompt surfaces queued messages as soon as it stops working.

Nothing is lost. Dedup across the two paths uses the `id:` marker.

Fan-in is covered. Several executors/reviewers can ack a busy orchestrator at once. Their sends queue on the orchestrator's per-target lock. Any send that can't paste live is recovered from the inbox. The send lock **waits for the full per-send budget and resets whenever the queue moves**. So fan-in to one pane does not trip "could not acquire send-lock". For an idle recipient the paste lands immediately. The inbox is the safety net for busy ones.

Condition: a recipient pane sits at an idle prompt (no turn in progress, no prompt coming). Neither hook fires in that case. Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` so the live paste itself succeeds.

## Reply correlation

Skill and command names (`/reply`, `session-chat:reply`) are not shell executables. There is no `reply.sh` or `session-chat reply` command.

To reply from a shell, run the installed helper `bash <plugin-root>/scripts/send-message.sh --reply-to <incoming-id> <pane> <message>`. For a file, use `dispatch-to-session.sh --reply-to`. Substitute the absolute plugin path literally.

Under strict-v1, read installed instructions with separate literal read commands (`cat <absolute-path>`). Chaining, pipes, and redirection do not qualify for cache read access.

Every `/send` and `/dispatch` has a unique `id:HEX8`. To reply, use **`/reply <pane> <message-id> <message>`**.

- `/reply` prepends the `[re:<id>]` correlation token for you (exactly once). The original sender's `/check-replies` then matches it.
- `/reply` auto-picks `/send` for a short reply or `/dispatch` for a long/multiline one.
- Pass the `id:<hex>` from the message you're answering. Do **not** hand-type `[re:<id>]` tokens.
- The raw transports also accept `--reply-to <id>` if you script them directly.
- When you ask a peer a question and expect an answer, tell it to `/reply` with your message id. Then poll `/check-replies --pending` instead of re-pinging panes that already answered.

## Staging files under a strict-v1 harness

Condition: a session-workspace strict-v1 harness is active and you are a child pane (reviewer, executor, or an environment-scoped coordinator). Stage long replies and dispatch prompt files **only** in your own drafts directory inside the granted messages store.

1. Find the store and your name.
   - `/session-workspace:workspace-plan` lists your pane with `grants: messages=<path>`.
   - `/session-chat:whoami` prints your pane name.
2. Check for the `messages` grant. **No `messages` grant means no staging exception. Fail closed.**
   - Do not use another staging location. The store top level and `$TMPDIR` are denied. Reviewers cannot write anywhere else. An executor's ordinary checkout write authority is not the staging contract.
   - Do not silently shorten a long reply to fit a single-line send.
   - Report that this pane has no `messages` grant, so a multiline dispatch is unavailable.
   - A genuinely short reply can still go out with `send-message.sh --reply-to`.
3. Create the file with the native write tool (Claude `Write`, Codex `apply_patch` Add File) at `<messages-path>/drafts/<your-pane-name>/<name>.md` (or `.txt`).
   - Use a fresh, unique name that includes a nonce, for example `reply-<incoming-id>-<date +%s output>.md`. A retained or concurrent draft is then never overwritten.
   - The first character must be an ASCII letter or digit. Later characters are only ASCII letters, digits, `.`, `_`, or `-`. The name has at most 128 characters before the extension.
   - You can create, edit, and delete only in your own drafts directory.
   - These are denied: renames/moves; shell writes (redirection, `tee`, `cp`, `mktemp`); other panes' drafts; files at the store top level; delivered messages and queue/archive/ledger state.
4. Dispatch it by absolute path: `bash <plugin-root>/scripts/dispatch-to-session.sh --reply-to <incoming-id> <pane> <messages-path>/drafts/<your-pane-name>/<name>.md` (omit `--reply-to` for a new task).
5. Handle the result.
   - **Durable success** (`Dispatched task to …` or `Queued dispatch …`): delete the draft with a native delete tool where one exists (Codex `apply_patch` Delete File).
     - Claude has no native delete tool, and shell `rm` into the store is denied. A Claude pane leaves the draft in place.
     - That draft is inert. The transport copies the content into a new delivered file and never reads `drafts/`.
   - **Hard failure** (`ERROR:` and non-zero exit): keep the draft, fix the named cause, and retry with the same file.

Nothing sweeps drafts automatically. Cleanup of leftovers is an explicit user request. The root orchestrator's existing authority over store files is unchanged.

## Reading complete dispatches under a strict-v1 harness

In `auto` mode the incoming hook inlines at most `SESSION_CHAT_DISPATCH_INLINE_MAX` characters (default 6000) of a trusted dispatch. It prints `Full task read command: cat '<absolute-path>'` **before** the body.

- That cap limits what is displayed, not the task size. Never split a task into numbered parts to fit it.
- `assist` offers the same command only for use after the local user approves.
- `notify` offers none.
- Incoming-mode consent rules are unchanged.

With session-workspace 0.10.0, reviewer and executor panes can run that command verbatim. The transport saves every dispatch at the top of the validated messages grant as `<epoch>-<pid>-<id>-<sender>-to-<recipient>.md`. A read is allowed only when all of these hold:

- the filename's endpoints resolve to exactly one pair of validated plan panes, with this pane as sender or recipient;
- the file is a private (no group/other bits), owned, single-link regular file directly in the grant, reached with no symlink component or `..` traversal;
- the command is one literal read (`cat`, `head`, `tail`, `wc`, `rg --no-config`, ...) with no pipe, redirection, expansion, glob, `git`, symlink-follow option, or `--files0-from` file list.

Your own existing drafts are readable the same way.

These are denied:

- other panes' messages and drafts
- queue/archive/ledger state
- subdirectories
- ungranted provider inboxes
- tool workdirs inside the store
- recursive reads from an ancestor of the store (`rg`, `find`, `du`, recursive `grep`, `ls -R`, including the implicit cwd). Name explicit subdirectories outside the store instead.

Reviewers no longer get the broad store reads they had before 0.10.0. Writes remain limited to your own drafts through the native write tool. strict-v1 does not gate Claude's native `Read` tool. So the command above is the portable path for both providers.

## Priorities and TTL

`/send`, `/dispatch`, and `/broadcast` all accept `--priority high` and `--ttl <minutes>`:

- `--priority high` — if the message ends up queued (recipient busy), it surfaces **before** normal-priority messages when the recipient's hook drains the inbox. Live delivery is unaffected (it is already immediate). Use it for abort signals and gating decisions, not routine status.
- `--ttl <minutes>` — if the message is still in the queue after this window, it is **dropped unsurfaced**. Use it for time-sensitive pings whose answer is useless later (e.g. "status now"). Never use it for task dispatches that must eventually run.

## Quoting and shell safety

The wrapper command (`/send`, `/dispatch`) passes the message via shell argv. When you construct the bash invocation:

- Always wrap the message in double quotes.
- Escape embedded `"`, `$`, and backticks. Or use single quotes if the payload has none of those.
- Multi-line payloads are not allowed for `/send`. Write the full prompt to a temp file and use `dispatch-to-session.sh <target> <file>` (which is what `/dispatch` does internally).

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
| `SESSION_CHAT_TARGET_MESSAGES_DIR` | unset (per-runtime default) | Overrides the local mailbox and every target mailbox; export the same absolute directory in all participating panes before starting their agents, otherwise senders and receivers can resolve different queues. |

## Helper commands

- `/broadcast [--all] [--match GLOB] <text>` — fan out one short message to every named pane (status pings, fleet-wide notices) instead of looping `/send` per pane.
- `/reply <pane> <message-id> <message>` — reply to a received message, auto-correlated: prepends the `[re:<id>]` token and picks `/send` (short) or `/dispatch` (long/multiline) for you. Use this instead of hand-typing `[re:<id>]`.
- `/check-replies [--pending] [--since MIN]` — which sent messages have a correlated reply (via `[re:<id>]` tokens) and which are still `unconfirmed`. This reflects reply **correlation only**, not the recipient's task progress or liveness. An `unconfirmed` row does not mean the pane is stuck. Use `/pane-health` to check liveness.
- `/pane-health [name] [--all]` — liveness, inbox backlog, and lock state per named pane; catches dead/duplicate panes before sends time out against them.
- `/message-search <pattern> [--days N] [--peer NAME]` — search the message archive (every sent + surfaced incoming message, 200-char excerpts, 30-day retention via `SESSION_CHAT_ARCHIVE_RETENTION_DAYS`) plus full dispatch bodies.
- `/incoming-mode` — show or set `SESSION_CHAT_INCOMING_MODE` (prints an `export` line to `eval`).
- `/messages-list` — read-only inventory of dispatch files under `${SESSION_CHAT_TARGET_MESSAGES_DIR:-${CLAUDE_HOME:-~/.claude}/messages}`.
- `/messages-clean` — delete old dispatch files (dry-run by default; pass `--apply` to actually delete).

## Common failure modes

- **"pane 'X' is at a shell prompt"** — the recipient's agent exited, and their shell would have executed the message. Restart the agent in that pane. Set `SESSION_CHAT_ALLOW_SHELL_TARGET=1` only for deliberate shell targets, e.g. tests.
- **"This pane has no name"** — run `/whoami <name>` in the sending pane first.
- **"No pane named X"** — run `/panes all` to see registered names across tmux sessions. The recipient might not have run `/whoami`.
- **"Multiple panes named X"** — duplicate names exist; rename one with `/whoami` in that pane.
- **"did not land within Xms after N attempts"** — the recipient stayed busy through all retries. The message is **not lost**. It is in the recipient's durable inbox and surfaces on their next turn (the sender reports "Queued …"). To make more sends land *live*, raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` or `SESSION_CHAT_SEND_RETRIES`.
- **"could not acquire send-lock"** — another sender is targeting the same pane. It resolves when that sender finishes. Raise `SESSION_CHAT_LOCK_TIMEOUT_MS` if you need to wait longer.
- **Dispatch lands but recipient never acts** — the recipient is in `INCOMING_MODE=notify` (default). It was told not to read the file. Run `/incoming-mode auto` (or `assist`) in the recipient's shell.

## Reload after install

Plugin updates do not auto-reload running sessions. After `claude plugin update session-chat@girishattri-plugins`:

1. The new version is unpacked under `~/.claude/plugins/cache/girishattri-plugins/session-chat/<version>/`. Confirm with `ls ~/.claude/plugins/cache/girishattri-plugins/session-chat/`.
2. Reload in the current session: `/reload-plugins`. This switches the plugin's hooks, commands, skills, and any MCP/LSP servers to the new version's path without a restart. Only monitors need a full session restart.
3. Verify: `/panes` and `/incoming-mode` should respond from the new version. If `/incoming-mode` reports "unknown command," the reload did not pick up the new commands. Check the cache path. Then restart Claude Code as the fallback.

A reload does **not** refresh environment variables the pane inherited at launch. These include `SESSION_CHAT_INCOMING_MODE`, `SESSION_CHAT_TARGET_MESSAGES_DIR`, and the context and scheduler homes. To change them, relaunch the pane with the new environment.

A plugin loaded in place from a local-directory marketplace (development checkouts) behaves differently. Edits to `SKILL.md` apply immediately. Edits to hooks or scripts apply at the next `/reload-plugins` or session start, with no version bump.

For codex-side parity, run `codex plugin marketplace upgrade girishattri-plugins`. Then start a **new Codex session** so the update is loaded. Its cache is under `~/.codex/plugins/cache/...`.
