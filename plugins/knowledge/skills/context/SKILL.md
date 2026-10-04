---
name: context
description: When and how to capture, restore, and hand off Claude context snapshots from the knowledge plugin's shared store. Use this skill before invoking /context-generate, /context-load, or /context-share so you understand what a snapshot is, where it lives, and the prerequisites for sharing one with another session.
---

# Context snapshots: knowledge shared store

A snapshot is a markdown summary of a working session. It records what you worked on, the decisions you made, and where you left off. A future session or a peer session can resume from it without re-deriving the state.

## Store location

Snapshots live in `SESSION_CONTEXT_HOME`. This variable must already be present in each pane's environment, **inherited when the agent process started**.

- The launcher or parent shell sets it before the agent starts.
- Every pane that shares snapshots must start with the same absolute value.
- The `/context-*` commands never export or derive it.
- Most scripts **fail closed** when it is unset. They do not guess a location. To fix this, relaunch the pane or session with the correct environment.
- `/context-search` scans across projects. It uses `SESSION_CONTEXT_HOME` only as an override for the current repo's store.
- A human may export `SESSION_CONTEXT_HOME=<dir>` in the parent shell before running a script directly.
- Agent-facing instructions never combine environment setup with helper execution. Invoke each helper as exactly one literal Bash segment that uses the inherited value.

Each snapshot is the file `$SESSION_CONTEXT_HOME/<name>.md`. `<name>` must be canonical `snake_case` (`^[a-z0-9]+(_[a-z0-9]+)*$`). The store hardening scanner applies the same rule to existing snapshot files and to `.history/<name>.<timestamp>.md` archives. Legacy hyphenated or uppercase context filenames fail closed until someone migrates them explicitly.

When every pane launches with the same shared store, every Claude or Codex pane in the same project sees the same snapshots.

A SessionStart hook lists existing snapshots automatically. It uses the inherited store. It uses a git-root default only for its own detection banner. A resuming session therefore learns that it can run `/context-load` instead of starting cold.

## When to use this plugin

- **Before you end or compact a long session:** run `/context-generate` to preserve the state you would otherwise lose.
- **When you resume work in a new session:** run `/context-list`, then `/context-load`, to continue where the previous session stopped.
- **When you hand work to a peer pane:** run `/context-share`. It notifies the other pane that a shared snapshot is available. It does not copy the file. The peer loads it from the same store.

Do not use a snapshot for a quick one-line status to another pane. Use `/send` for that. Snapshots are for substantial, reusable state.

## Generate runs in the working session

`/context-generate` summarizes the current conversation. It must run in the session that did the work. A fresh subagent has none of that context and cannot produce the summary. Never delegate generation to a separate agent.

## Lifecycle

```
/context-generate [name]   → writes $SESSION_CONTEXT_HOME/<name>.md
                             (overwrite archives the old version to $SESSION_CONTEXT_HOME/.history/)
  ↓
/context-list              → see what snapshots exist (name, size, last updated, versions)
  ↓
/context-load <name>       → read a snapshot back into the current session
  ↓ (optional)
/context-diff <name>       → compare the current snapshot with an archived version
/context-verify <name> --repository-id <id> → verify a v2 handoff's local evidence (read-only)
  ↓ (optional)
/context-share <session> [name]  → notify the named pane a shared snapshot is available
  ↓ (when stale)
/context-remove <name>     → delete a snapshot
```

## Commands

| Command | Purpose |
|---|---|
| `/context-generate [name] [--handoff] [--expires <UTC-ISO>]` | Summarize the current session and save it (overwrites a same-named snapshot; the previous version is archived). Omit the name to derive one from the session/directory name. `--handoff` writes a structured handoff whose scope, work items, statuses, and evidence follow the [handoff evidence contract](../knowledge/references/handoffs.md). |
| `/context-list` | List snapshots for this project (name, line count, last modified, history version count). |
| `/context-load <name>` | Load a snapshot's contents into the current session. Warns if the snapshot is 7 or more days old (override with `SESSION_CONTEXT_STALE_DAYS`). |
| `/context-diff <name>` | Unified diff of the newest archived version vs. current. `--versions` lists timestamps; pass a timestamp to diff that version. |
| `/context-verify <name> --repository-id <id> [--repo <path>] [--json]` | Read-only verification of a v2 handoff's `file`/`commit` evidence and `scope.paths` against the bound repository (existence and type, commit presence and `HEAD` ancestry) using fixed read-only Git queries; `test`/`reference` evidence and symlinks stay unverified. `--repository-id` must match the saved `scope.repository`. Exit 1 when anything is missing, mismatched, or left unverified. See the [handoff evidence contract](../knowledge/references/handoffs.md). |
| `/context-search <pattern> [--list]` | Read-only search of snapshot *contents* across local projects (current repo always; other roots best-effort via decoded session paths — lossy for hyphenated directory names). |
| `/context-share <session> [name]` | Notify another pane that a shared snapshot is available (same store; not a file copy). |
| `/context-remove <name>` | Delete a snapshot. |

Snapshot and handoff names are canonical knowledge item names: lowercase `snake_case` slugs that match `^[a-z0-9]+(_[a-z0-9]+)*$`. When you derive a default from a session or directory name, normalize it to that form. Do not put dates or datetimes in the name.

## Sharing prerequisites

`/context-share` notifies another pane over tmux. Check these three conditions first.

1. **You are inside tmux.** Sharing works only in tmux.
2. **The recipient pane has a name.** Name it via `/whoami <name>` or SessionStart auto-naming when session-chat is installed. Panes are addressed by name, and the search spans all tmux sessions. The sender also needs a name for fallback transport.
3. **The recipient inherits the same context store.** Sharing is not a file copy. It relies on the launcher-selected `$SESSION_CONTEXT_HOME` directory being shared. It then sends the peer a one-line message that carries the canonical store path. The message tells the peer to run `/context-load <name>`, which resolves against the peer's own store. A peer in a different repo or store does not have the snapshot to load.

Sharing uses the hardened transport of session-chat when it is installed. That transport is a durable inbox, so a busy recipient still gets the notice on its next turn. If session-chat is absent, sharing falls back to the basic tmux send of this plugin. The same-store prerequisite does not change.

Listing, generating, loading, and removing snapshots work outside tmux. Only sharing requires tmux.

## Conventions

- **Snapshots are store-local, not global.** The launcher-selected `SESSION_CONTEXT_HOME` determines the snapshot set. Every pane that inherits the same absolute store sees the snapshot, regardless of cwd.
- **Context is temporary working state, not durable memory.** Keep each snapshot focused on what a future session needs next. When the information stabilizes, promote it to memory or docs. When it no longer matters, remove it with `/context-remove`.
- **Regenerate, do not append.** `/context-generate` with an existing name overwrites that snapshot with the current state. Keep one authoritative snapshot per name. Overwriting is safe. The previous version is archived to `$SESSION_CONTEXT_HOME/.history/<name>.<timestamp>.md`. The timestamp format is `YYYYMMDD-HHMMSS+HHMM` in `AGENT_PLUGINS_TIME_ZONE` (default `Asia/Kolkata`). The 10 most recent versions are kept. `/context-diff <name>` shows what changed since the last version.
- **Watch for staleness.** `/context-load` appends a WARNING when the snapshot file is 7 or more days old. Set the threshold with `SESSION_CONTEXT_STALE_DAYS`. Regenerate the snapshot instead of trusting old state.
- **Clean up stale snapshots** with `/context-remove`. This keeps `/context-list` and the SessionStart hint meaningful.

## Failure modes

| Message or symptom | Cause | Next action |
|---|---|---|
| "No snapshots found" | No snapshot exists for this project. | Run `/context-generate`. |
| "No pane named X" on share | The recipient has not run `/whoami`, or the name is wrong. | Run `/panes all` to see named panes. Then share again with the correct name. |
| Sharing error about tmux | You are not inside a tmux session. | Share from inside tmux. Generate, list, load, and remove still work. |
