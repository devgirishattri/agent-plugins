---
description: Dispatch a tracked task to an existing named session
argument-hint: <session-name> <prompt>
allowed-tools: Bash(bash:*), Write
---

## Instructions

Do not narrate or add a preamble. Run the script directly and report only the result.

`/dispatch` is for **task hand-off** — multi-line prompts, code, structured work. The full prompt is written to a file under the recipient runtime's messages dir (`~/.claude/messages/` for a Claude pane, `~/.codex/messages/` for a Codex pane) and the recipient gets a one-line notification with the file path. See the `session-chat` skill for the full contract, recipient prerequisites, and `INCOMING_MODE` requirements.

1. Parse $ARGUMENTS: optional `--priority high` (surfaces before normal messages if queued) and `--ttl <minutes>` (drop instead of surfacing if still queued after the window) come first; then the target session name; everything after is the prompt.

2. If $ARGUMENTS is empty or has no prompt after the session name, ask the user:
   "Usage: `/dispatch [--priority high] [--ttl <minutes>] <session-name> <task prompt>`"

3. Stage the prompt to a file with the **Write tool**, then dispatch that file. Do NOT embed the task text in a shell heredoc or command — arbitrary content is unsafe as shell source (a body line equal to a heredoc delimiter would terminate it and run the following text as shell). The Write tool writes the body as data, never as shell:
   1. Choose a fresh temp path (e.g. `$(mktemp)` obtained via a separate Bash call, or a file under your scratchpad dir).
   2. Use the **Write tool** to write the **verbatim prompt body** to that path — never interpolate the body into a bash command.
   3. Dispatch it (the script reads the file with `cat`; nothing in it is shell-evaluated):
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/dispatch-to-session.sh [--priority high] [--ttl <minutes>] "<target>" "<prompt-file-path>"
   ```
   4. Optionally remove the temp file afterward with `rm -f "<prompt-file-path>"`.

4. Report the script's result **verbatim** — both success cases are fine, but they mean different things:
   - `Dispatched task to '<target>'` — the prompt landed live in the recipient's pane now.
   - `Queued dispatch to '<target>' — recipient was busy; it will arrive on their next turn.` — durable delivery; the recipient's inbox surfaces it on its next turn. **This is success — do not re-dispatch.**
   Then add: "Use `/panes` to check status or `/send <target> <message>` to follow up. Note: if `<target>` runs with `SESSION_CHAT_INCOMING_MODE=notify` (default) they will be **told not to read** the dispatch file — set `auto` or `assist` for orchestration."

5. If error about target not found, run `/panes` to show available sessions.
6. If error about no name, tell user to run `/whoami <name>` first.
7. If error mentions duplicate names, ask the user to rename one pane via `/whoami`.
8. **Do not retry a `Queued …` result** — durable delivery surfaces it on the recipient's next turn, so re-dispatching only duplicates the task. (Raising `SESSION_CHAT_VERIFY_TIMEOUT_MS` only makes more dispatches land *live*; it does not change whether delivery happens.) Only a **hard failure** — the script prints an `ERROR:` and exits non-zero (no name, unknown/ambiguous target) — should be retried, after fixing the named cause.
