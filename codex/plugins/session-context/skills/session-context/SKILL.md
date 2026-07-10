---
name: session-context
description: "Understand when and how to capture, restore, search, remove, and hand off Codex session-context snapshots, including their shared-store and tmux prerequisites."
---

# Session Context

A snapshot is a concise Markdown summary of a working session: what changed, key decisions, open issues, and where work stopped. Use it when another Codex session must continue without re-deriving the state.

Snapshots live under `SESSION_CONTEXT_HOME`. Each `$session-context:context-*` skill exports a default of `<git-root>/tmp/contexts` (falling back to `<pwd>/tmp/contexts`) unless the environment already points to an intentionally shared directory. Direct script callers must set the variable explicitly; the scripts fail closed when it is absent. The store is private by default: directories are owner-only, regular files are owner-only (scheduler-created immutable snapshots remain `0400`), and unsafe symlinked, unowned, or special-file paths are rejected before content access.

## When to use it

- Before ending or compacting a long session: `$session-context:context-generate [name]`.
- When resuming work: `$session-context:context-list`, then `$session-context:context-load <name>`.
- When handing substantial state to a named tmux pane: `$session-context:context-share <session> [name]`.
- For a quick one-line update instead, use `$session-chat:send`.

Generate the snapshot in the session that did the work. A fresh subagent does not have the current conversation and must not be asked to reconstruct it.

## Lifecycle

```text
$session-context:context-generate [name]
  -> writes SESSION_CONTEXT_HOME/<name>.md
  -> archives an overwritten version under .history/ (10 newest retained)
  -> context-list / context-load / context-diff / context-search
  -> optional context-share notification to a peer
  -> context-remove when stale
```

| Skill | Purpose |
|---|---|
| `$session-context:context-generate [name]` | Summarize the current session and save it. |
| `$session-context:context-list` | List snapshot names, line counts, timestamps, and history counts. |
| `$session-context:context-load <name>` | Load and internalize a snapshot; warn when stale. |
| `$session-context:context-diff <name>` | Compare the current snapshot with archived versions. |
| `$session-context:context-search <pattern> [--list]` | Search snapshot contents across discoverable local projects. |
| `$session-context:context-share <session> [name]` | Notify another named tmux pane that a snapshot is available. |
| `$session-context:context-remove <name>` | Preview, explicitly confirm, and delete one snapshot. |

Snapshot names may contain only letters, numbers, hyphens, and underscores.

## Sharing prerequisites

Sharing sends a notification; it does **not** copy the snapshot file. Therefore:

1. The sender must run inside tmux and have a reachable pane name.
2. The recipient pane must be named and reachable through session-chat/tmux.
3. Sender and recipient must resolve the same `SESSION_CONTEXT_HOME`. This normally means they are in the same repository, or their workspace explicitly pins both panes to one shared context directory.

A recipient in another repo with a different context home cannot load the snapshot merely because it received the notification. When session-chat is installed, sharing uses its hardened delivery/queue path; otherwise it falls back to the local tmux sender.

## Conventions

- Regenerate an authoritative named snapshot instead of appending competing copies; history preserves overwritten versions.
- Treat a staleness warning as a prompt to regenerate rather than blindly trusting old state.
- Remove obsolete snapshots so startup hints and lists remain useful.
- Listing, generating, loading, diffing, searching, and removing work outside tmux; only sharing requires tmux.

## Failure modes

- No snapshots: run `$session-context:context-generate`.
- No target pane: run `$session-chat:panes` and verify the recipient name.
- Recipient cannot load after a successful share: verify both panes use the same absolute `SESSION_CONTEXT_HOME`.
- Sharing reports no tmux session: start Codex inside tmux; other snapshot operations remain available.
