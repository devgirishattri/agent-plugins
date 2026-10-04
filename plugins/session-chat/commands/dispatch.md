---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
allowed-tools: Bash(bash:*), Write
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. Run the script directly and report only the result.

`/dispatch` is for **task hand-off**: multi-line prompts, code, and structured work. The script writes the full prompt to a file under the recipient runtime's messages dir (`~/.claude/messages/` for a Claude pane, `~/.codex/messages/` for a Codex pane). The recipient gets a one-line notification with the file path. See the `session-chat` skill for the full contract, recipient prerequisites, and `INCOMING_MODE` requirements.

1. Parse $ARGUMENTS. Optional flags come first. `--priority high` surfaces the message before normal messages if queued. `--ttl <minutes>` drops the message instead of surfacing it if still queued after the window. Then comes the target session name. Everything after is the prompt.

2. If $ARGUMENTS is empty or has no prompt after the session name, ask the user:
   "Usage: `/dispatch [--priority high] [--ttl <minutes>] <session-name> <task prompt>`"

3. Stage the prompt to a file with the **Write tool**, then dispatch that file. Do NOT embed the task text in a shell heredoc or command. Arbitrary content is unsafe as shell source. A body line equal to a heredoc delimiter would end the heredoc. The following text would then run as shell. The Write tool writes the body as data, never as shell:
   1. Choose a fresh temp path (e.g. `$(mktemp)` obtained via a separate Bash call, or a file under your scratchpad dir). **Under an active strict-v1 harness as a child pane**, use only your own drafts directory: `<messages-grant>/drafts/<your-pane-name>/<name>-<nonce>.md`. Follow "Staging files under a strict-v1 harness" in the `session-chat` skill. With no `messages` grant there is no staging exception. Report the missing grant. Do not substitute another location.
   2. Use the **Write tool** to write the **verbatim prompt body** to that path. Never interpolate the body into a bash command.
   3. Dispatch it. The script reads the file with `cat`, so nothing in it is shell-evaluated:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh [--priority high] [--ttl <minutes>] "<target>" "<prompt-file-path>"
   ```
   4. Optionally remove the temp file afterward with `rm -f "<prompt-file-path>"`. Under strict-v1, leave the draft in place. Claude has no native delete tool, shell `rm` into the store is denied, and the draft is inert after delivery. After a hard failure, keep the draft for the retry.

4. Report the script's result **verbatim**. Both success cases are fine, but they mean different things:
   - `Dispatched task to '<target>'` — the prompt landed live in the recipient's pane now.
   - `Queued dispatch to '<target>' — recipient was busy; it will arrive on their next turn.` — durable delivery. The recipient's inbox surfaces it on its next turn. **This is success — do not re-dispatch.**
   Then add: "Use `/panes` to check status or `/send <target> <message>` to follow up. Note: if `<target>` runs with `SESSION_CHAT_INCOMING_MODE=notify` (default), they will be **told not to read** the dispatch file. Set `auto` or `assist` for orchestration."

5. If the error says the target is not found, run `/panes` to show available sessions.
6. If the error is about no name, tell the user to run `/whoami <name>` first.
7. If the error mentions duplicate names, ask the user to rename one pane via `/whoami`.
8. Raising `SESSION_CHAT_VERIFY_TIMEOUT_MS` only makes more dispatches land *live*. It does not change whether delivery happens. Retry only a **hard failure**, and only after fixing the named cause. A hard failure is an `ERROR:` print with a non-zero exit (no name, unknown or ambiguous target).
