---
name: session-context
description: When and how to capture, restore, and hand off Claude session context snapshots for a project. Use this skill before invoking /context-generate, /context-load, or /context-share so you understand what a snapshot is, where it lives, and the prerequisites for sharing one with another session.
---

# session-context: project-local context snapshots

A snapshot is a markdown summary of a working session — **what you worked on, the
decisions you made, and where you left off** — written so a *future* session (or a
peer session) can resume without re-deriving everything from scratch.

Snapshots are stored under `SESSION_CONTEXT_HOME`, which must already be present in each pane's environment, **inherited when the agent process started** — the launcher/parent shell establishes it before the agent starts, and every pane that shares snapshots must be launched with the same absolute value. The `/context-*` commands never export or derive it, and most scripts **fail closed** when it is unset rather than guessing a location; the fix is to relaunch the pane/session with the correct environment (`/context-search`, which scans across projects, is the exception — it uses `SESSION_CONTEXT_HOME` only as an override for the current repo's store). Direct human script use may export `SESSION_CONTEXT_HOME=<dir>` in the parent shell beforehand, but agent-facing instructions never combine environment setup with helper execution — each helper is invoked as exactly one literal Bash segment using the inherited value.

Snapshots live at `$SESSION_CONTEXT_HOME/<name>.md`. Launching every pane with the
same shared store means every Claude/Codex pane working in the same project sees
the same set of snapshots.

A SessionStart hook surfaces existing snapshots automatically (using the inherited
store, with a git-root default only for its own detection banner), so a resuming
session is told it can `/context-load` instead of starting cold.

## When to use this plugin

- **Before ending or compacting a long session** — run `/context-generate` to
  preserve the state you'd otherwise lose.
- **When resuming work** in a new session — `/context-list` then `/context-load` to
  pick up where the previous session stopped.
- **When handing work to a peer pane** — `/context-share` notifies another pane
  that a shared snapshot is available (it does not copy the file; the peer loads
  it from the same store).

**Don't use it for** a quick one-line status to another pane — that's
`/session-chat:send`. Snapshots are for substantial, reusable state.

## Generate runs in the working session — it cannot be delegated

`/context-generate` summarizes *the current conversation*, so it must run in the
session that did the work. A fresh subagent has none of that context and cannot
produce the summary — never try to offload generation to a separate agent.

## Lifecycle

```
/context-generate [name]   → writes <project_root>/tmp/contexts/<name>.md
                             (overwrite archives the old version to tmp/contexts/.history/)
  ↓
/context-list              → see what snapshots exist (name, size, last updated, versions)
  ↓
/context-load <name>       → read a snapshot back into the current session
  ↓ (optional)
/context-diff <name>       → compare the current snapshot with an archived version
  ↓ (optional)
/context-share <session> [name]  → notify the named pane a shared snapshot is available
  ↓ (when stale)
/context-remove <name>     → delete a snapshot
```

## Commands

| Command | Purpose |
|---|---|
| `/context-generate [name]` | Summarize the current session and save it (overwrites a same-named snapshot; the previous version is archived). Omit the name to derive one from the session/directory name. |
| `/context-list` | List snapshots for this project (name, line count, last modified, history version count). |
| `/context-load <name>` | Load a snapshot's contents into the current session. Warns if the snapshot is 7 or more days old (override with `SESSION_CONTEXT_STALE_DAYS`). |
| `/context-diff <name>` | Unified diff of the newest archived version vs. current. `--versions` lists timestamps; pass a timestamp to diff that version. |
| `/context-search <pattern> [--list]` | Read-only search of snapshot *contents* across local projects (current repo always; other roots best-effort via decoded session paths — lossy for hyphenated directory names). |
| `/context-share <session> [name]` | Notify another pane that a shared snapshot is available (same store; not a file copy). |
| `/context-remove <name>` | Delete a snapshot. |

Snapshot names must contain only letters, numbers, hyphens, and underscores.

## Sharing prerequisites

`/context-share` notifies another pane over tmux, so:

1. **You must be inside tmux** — sharing is a tmux-only operation.
2. **The recipient pane must be named** (via `/whoami <name>` or SessionStart
   auto-naming); names are how panes are addressed, and the search spans all
   tmux sessions.
3. **The recipient should be working in the same repo / context store.** Sharing
   does *not* copy the snapshot file — it relies on the project-local
   `tmp/contexts/` dir being shared, then sends the peer a one-line message
   (carrying the canonical store path) telling them to run `/context-load
   <name>`, which resolves against the *peer's own* store. A peer in a different
   repo/store won't have the snapshot to load.

Sharing prefers session-chat's hardened transport when it's installed (durable
inbox — a busy recipient still gets the notice on its next turn); if session-chat
is absent it falls back to this plugin's basic tmux send. Either way the
same-store prerequisite above is unchanged.

Listing, generating, loading, and removing snapshots work outside tmux — only
sharing requires it.

## Conventions

- **Snapshots are project-local, not global.** Switching repos switches the
  snapshot set; a snapshot generated in repo A is not visible in repo B.
- **Regenerate, don't append.** `/context-generate` with an existing name overwrites
  that snapshot with the current state — keep one authoritative snapshot per name
  rather than many stale ones. Overwriting is safe: the previous version is archived
  to `tmp/contexts/.history/<name>.<UTC timestamp>.md` (10 most recent kept), and
  `/context-diff <name>` shows what changed since the last version.
- **Watch for staleness.** `/context-load` appends a WARNING when a snapshot's file
  is 7+ days old (threshold configurable via `SESSION_CONTEXT_STALE_DAYS`) — regenerate
  rather than trusting old state.
- **Clean up stale snapshots** with `/context-remove` so `/context-list` and the
  SessionStart hint stay meaningful.

## Failure modes

- **"No snapshots found"** — none exist for this project yet; run
  `/context-generate` first.
- **"No pane named X" on share** — the recipient hasn't run `/whoami`, or you typed
  the wrong name. Run `/session-chat:panes` to see named panes.
- **Sharing errors about tmux** — you're not inside a tmux session; sharing needs
  tmux. Generate/list/load/remove still work.
