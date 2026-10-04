---
name: session-chat
description: "Coordinate Codex sessions over tmux with guidance for choosing send vs dispatch, recipient setup, reliability tunables, and common failure modes."
---

# Session Chat

Use this skill when the user asks how session-chat works, which command to use, how to configure receiving panes, or how to troubleshoot delivery.

The `$session-chat:*` names select skills; they are not shell executables or
Codex internal agent-messaging tools. Read the selected skill and invoke its
installed Bash helper. Replies use `send-message.sh --reply-to <incoming-id>`
(or `dispatch-to-session.sh --reply-to` for a file), never a guessed `reply.sh`
or `session-chat reply` command. Under strict-v1, read installed instructions
with separate literal read commands, such as `cat <absolute-skill-path>`;
shell chaining, pipes, and redirection do not qualify for cache read access.

## Choosing A Command

| Use case | Command | Notes |
| --- | --- | --- |
| Short status, acknowledgement, or question | `$session-chat:send <pane> <message>` | Single line only, up to `SESSION_CHAT_SEND_MAX_LEN` characters. Default max is 1024. |
| Multi-line task, code, logs, or detailed report | `$session-chat:dispatch <pane> <task>` | Writes the full prompt to a trusted message file and sends a notification. |
| Work that should be tracked and resumed from a file | `$session-chat:dispatch <pane> <task>` | Receiver sees the file path, line count, and message id. |
| Unsure whether content might contain newlines or shell-sensitive text | `$session-chat:dispatch <pane> <task>` | Avoids send payload limits and inline quoting ambiguity. |
| Reply or acknowledgement to an incoming message | `$session-chat:reply <pane> <id> <message>` | Transport adds `[re:<id>]` exactly once; do not type the token manually. |

## Recipient Prerequisites

- The recipient must be running inside tmux.
- The recipient pane must have a unique registered name, either from `$session-chat:whoami <name>` or best-effort SessionStart auto-naming from the transcript's first user message.
- Use `$session-chat:panes` to inspect the current tmux session, or `$session-chat:panes all` when the target may be in another tmux session.
- In Codex, the plugin `hooks.json` runs on `SessionStart` and `UserPromptSubmit` to load tmux styling, auto-name unnamed panes when possible, and surface incoming messages according to `SESSION_CHAT_INCOMING_MODE`.
- For orchestration, the recipient should set `SESSION_CHAT_INCOMING_MODE=auto` or `SESSION_CHAT_INCOMING_MODE=assist`.
- The default `SESSION_CHAT_INCOMING_MODE=notify` treats incoming content as untrusted, forbids reading dispatch files, and asks the local user before acting. Dispatches can appear to no-op in this mode.

## Recipient Format

Direct messages are submitted as:

```text
[from:<sender> pane:<pane-id> id:<id>] <message> [id:<id>]
```

Dispatch notifications are submitted as:

```text
[from:<sender> pane:<pane-id> msg:<message-file> id:<id>] dispatch (<line-count> lines) — read msg file for full task id:<id>
```

The trailing id keeps the verification marker visible in TUIs that show the end of long input lines. In `auto`, the hook validates ownership, permissions, symlinks, and canonical containment, then inlines a bounded task body. `assist` and `notify` never inline it.

With session-workspace 0.10.0, reviewers and executors can read complete
delivered files addressed to or sent by their validated pane using the literal
`cat '<absolute-path>'` command shown before the inline body. Keep the existing
incoming-mode consent rules. `SESSION_CHAT_DISPATCH_INLINE_MAX` (default 6000)
limits displayed characters, not the complete task. The full transport copy is
saved directly in the validated messages grant as
`<epoch>-<pid>-<id>-<sender>-to-<recipient>.md`; drafts remain under
`drafts/<own-pane>/`. Sending retains the existing coordinator routes.

Only private, owned, single-link regular delivered files with no symlink
component or traversal qualify. Both filename endpoints must resolve uniquely
in the validated plan. Own existing drafts are readable too; unrelated
messages, peer drafts, queue/archive/ledger state, subdirectories and ungranted
provider inboxes are denied. Reviewers lose their former broad store reads.
Use one literal read command, without pipes, redirection, expansion, globs,
`sed` or symlink-follow options. Recursive ancestor searches into the store are
denied; name explicit safe subdirectories. Writes still use native tools only
for own drafts. Coordinator behavior and Claude's ungated native Read remain
unchanged. Update both plugins and restart affected panes.

## Staging files under a strict-v1 harness

Under an active strict-v1 harness, a reviewer, executor, or confined coordinator
must stage in `<validated-messages-grant>/drafts/<validated-pane-name>/`.

1. Resolve the grant and identity from the validated workspace plan or launch context.
   Use `$session-workspace:workspace-plan` if needed. Never derive or export store variables to grant access.
2. If the messages grant or native writer is unavailable, stop and report the missing capability.
   Do not truncate the reply or fall back to shell interpolation.
3. Choose a fresh filename, such as `reply-<incoming-id>-<nonce>.md`.
   The stem starts with an ASCII letter or digit and contains only ASCII letters, digits, `.`, `_`, or `-`.
   Its maximum length is 128 characters. Use the suffix `.md` or `.txt`.
4. Use native `apply_patch` to create, revise, or delete only your own draft.
   Shell staging and shell cleanup are blocked.
   Never write transport messages, other panes' drafts, or queue/archive/ledger state.
   Symlinks, hardlinks, moves, and patches mixing drafts with other files are forbidden.

Outside this harness, create a temporary directory with `mktemp -d` in a separate
shell call and use a native tool to write the file there.

Use file dispatch for multiline, long, or command-containing/quoting-sensitive
messages. For replies, always pass the incoming id through `--reply-to`. The
helper creates a separate durable transport copy. After delivered or durable
queued success, delete only your own draft with a native tool; keep it after a
hard failure. Cleanup is explicit, with no automatic draft retention sweep.

## Reliability Contract

Session-chat takes a per-target lock before writing to a pane, sends text with `tmux send-keys -l`, verifies either a marker or a newly-created `[Pasted text #N]` placeholder in `capture-pane -S -200`, then sends a three-pair line-edit clear sequence (`C-e C-u`, `C-a C-k`, `C-e C-u`) for any partial paste, backs off, and retries before returning failure.

Codex TUI redraws, wrapping, approval prompts, and active command output can still hide typed markers from `capture-pane`. The wrapper converts that timeout into a durable `Queued ...` success when the fallback was recorded; do not retry a queued result. Raising the verification timeout only increases the chance of immediate live delivery.

| Delivery outcome | Required action |
|---|---|
| Live delivery succeeds | Continue. Do not resend. |
| Durable `Queued ...` success | The fallback is recorded. Do not retry the message. |
| Hard failure without a queued success | Fix the reported cause before retrying. |

A delivery receipt confirms transport, not task completion.
Check the recipient's correlated reply or task evidence before reporting completion.
If that evidence is unavailable, report task completion as unverified.

For durable fallback, the sender writes the queue row and dispatch file into the recipient runtime's message directory. Codex recipients use `${CODEX_HOME:-~/.codex}/messages`; Claude recipients use `${CLAUDE_HOME:-~/.claude}/messages`. When `SESSION_CHAT_TARGET_MESSAGES_DIR` is exported in every participating pane, it becomes the shared sender and receiver mailbox root instead. Queue operations lock under that message directory so mixed Codex/Claude fallback does not depend on both runtimes sharing the same `TMPDIR`.

Session-chat uses umask `077`, enforces directories `0700` and files `0600`, and performs a one-time safe migration of an existing owner-owned, non-symlink message tree. Every operation revalidates queue, lock, archive, and ledger paths; symlinked, multiply-linked, non-regular, or unowned paths are rejected. Dispatch files use atomic no-clobber creation and are revalidated before notification and before trusted reads.

## Tunables

- `SESSION_CHAT_VERIFY_TIMEOUT_MS`: marker verification timeout in milliseconds. Default: `4000`.
- `SESSION_CHAT_SETTLE_MS`: delay after a successful Enter. Default: `300`.
- `SESSION_CHAT_SEND_MAX_LEN`: maximum `$session-chat:send` payload length. Default: `1024`.
- `SESSION_CHAT_SKIP_VERIFY`: set to `1` to skip marker verification.
- `SESSION_CHAT_INCOMING_MODE`: receiver behavior. Values: `notify`, `assist`, `auto`, `off`. Default: `notify`.
- `SESSION_CHAT_LOCK_TIMEOUT_MS`: how long a sender waits for a per-pane send lock. Default: auto-derived from the send budget (~4× one send) and reset whenever the lock holder changes, so fan-in to one pane queues instead of failing. When set explicitly, it is a hard cap.
- `SESSION_CHAT_SEND_RETRIES`: retry count after verify timeouts. Default: `2`.
- `SESSION_CHAT_RETRY_BACKOFF_MS`: linear retry backoff base in milliseconds. Default: `200`.
- `SESSION_CHAT_QUEUE_RECOVERY_GRACE_MS`: how long a pre-live durable queue row waits before hook recovery if the sender dies mid-send. Default: auto-derived from lock plus send budget plus 1000ms; known live-send failures mark the row ready immediately.
- `SESSION_CHAT_RECENT_ID_TTL_MS`: how long surfaced message ids suppress duplicate live arrivals. Default: `600000`.
- `SESSION_CHAT_DISPATCH_INLINE_MAX`: maximum trusted dispatch-body characters inlined in `auto` mode. Default: `6000`; total hook context remains capped at `10000`.
- `SESSION_CHAT_TARGET_MESSAGES_DIR`: overrides the local mailbox and every target mailbox. Export the same absolute directory in all participating panes before starting their agents; otherwise senders and receivers can resolve different queues.

## Common Failures

- `Operation not permitted` or `Permission denied` while accessing tmux: the
  sandbox blocked the tmux socket. This is not an empty pane list, an unnamed
  pane, or a missing target. Relay the error and rerun the entire plugin script
  escalated/approved; retrying only one inner `tmux` command is insufficient.
- `did not land within Xms after N attempts` followed by `Queued ...`: target was busy through all live attempts, but the message is **not lost** — it is already in the recipient's resolved durable inbox. Without `SESSION_CHAT_TARGET_MESSAGES_DIR`, the defaults are `${CODEX_HOME:-~/.codex}/messages/queue/<name>.tsv` for Codex and `${CLAUDE_HOME:-~/.claude}/messages/queue/<name>.tsv` for Claude; with the override, the queue is under `$SESSION_CHAT_TARGET_MESSAGES_DIR/queue/<name>.tsv`. Do not retry the queued message. It surfaces on the recipient's next prompt (`UserPromptSubmit` hook) or as soon as the current turn finishes (`Stop` hook feedback). Raise `SESSION_CHAT_VERIFY_TIMEOUT_MS` or `SESSION_CHAT_SEND_RETRIES` only when immediate live landing matters.
- `timed out waiting for send lock`: rare now that the unset lock timeout auto-sizes to the send budget and resets on holder change. If `SESSION_CHAT_LOCK_TIMEOUT_MS` is set, that value is treated as an absolute cap.
- `pane 'X' is at a shell prompt`: the recipient's agent exited; the message would have been executed by their shell. Restart the agent in that pane (set `SESSION_CHAT_ALLOW_SHELL_TARGET=1` only for deliberate shell targets, e.g. tests).
- `Multiple panes named X`: rename one pane with `$session-chat:whoami <name>` in that pane.
- `No pane named X`: run `$session-chat:panes all` and confirm the recipient has a unique registered name; use `$session-chat:whoami <name>` there if SessionStart auto-naming did not provide one.
- `$session-chat:send only supports single-line messages`: use `$session-chat:dispatch`.
- `$session-chat:send payload exceeds ... characters`: use `$session-chat:dispatch`.

## Incoming Mode

Use `$session-chat:incoming-mode` to show the current receiver mode and explain `notify`, `assist`, `auto`, and `off`. The `UserPromptSubmit` hook reads this value when incoming tmux messages are submitted to Codex, then emits model-visible `hookSpecificOutput.additionalContext` capped at 10000 characters. Use `$session-chat:incoming-mode auto` or another mode to print an `export SESSION_CHAT_INCOMING_MODE=<mode>` command. Run that export in the shell that starts Codex, then restart or reload the session; a child script cannot mutate the parent Codex environment.

## Message Files

Use `$session-chat:messages-list` to inspect trusted dispatch message files in `${SESSION_CHAT_TARGET_MESSAGES_DIR:-${CODEX_HOME:-~/.codex}/messages}`. `$session-chat:messages-clean` always previews first and requires a separate explicit confirmation before running with `--apply`.

## Priorities and TTL

`$session-chat:send`, `$session-chat:dispatch`, and `$session-chat:broadcast` accept `--priority high` (a queued message surfaces before normal ones when the recipient drains its inbox — use for abort signals and gating decisions) and `--ttl <minutes>` (a message still queued after the window is dropped unsurfaced — use for time-sensitive pings, never for tasks that must eventually run).

## Fleet Helpers

- `$session-chat:broadcast [--all] [--match GLOB] <text>`: fan out one short message to every named pane (status pings, fleet-wide notices) instead of looping `$session-chat:send` per pane.
- `$session-chat:message-search <pattern> [--days N] [--peer NAME]`: search the message archive plus full dispatch bodies. The archive holds every sent and surfaced incoming message as a 200-character excerpt, with 30-day retention.
- `$session-chat:check-replies [--pending] [--since MIN]`: which sent messages have confirmed correlated replies. Use `$session-chat:reply <pane> <id> <message>` for responses; it generates `[re:<id>]` automatically. An unconfirmed row is not evidence that the peer still has an active task.
- `$session-chat:pane-health [name] [--all]`: liveness, cwd/location, inbox backlog, and lock state per named pane; catches dead, duplicate, or repo-drifted workers before dispatch.

## Reinstalling Source Changes

This source tree may be newer than the running Codex plugin cache. To make the running registry pick up this version after publishing or local marketplace refresh, run:

```bash
codex plugin marketplace upgrade girishattri-plugins
```

Verify the installed version with `codex plugin list --json` and check that the
intended skills and hooks are visible in the running session. Start a new Codex
session if content remains stale; review changed hook trust separately. Plugin
refresh does not replace launch-inherited environment, which requires relaunch.
Inspect `$HOME/.codex/plugins/cache/girishattri-plugins/session-chat/` only when
diagnosing installed contents; never patch that cache manually.
