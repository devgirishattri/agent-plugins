# Cross-Project Context Sharing

**Date**: 2026-03-29
**Updated**: 2026-04-29
**Status**: Implemented manually; automatic dispatch attachment is future work
**Related**: `TODO.md`

## Overview

The `session-context` plugin lets agent sessions working in different project directories exchange project knowledge. A session can generate a concise context snapshot, list available snapshots, load one into its current work, or share it with another named tmux session.

This is useful when an orchestrator session dispatches work to another project. The receiving session can load API contracts, schemas, conventions, and architecture notes before making changes.

## Commands

| Command | Purpose |
|---------|---------|
| `/context-generate [snapshot-name]` | Generate a context snapshot for the current project |
| `/context-share <session> [snapshot-name]` | Notify another named session about a snapshot |
| `/context-load <snapshot-name>` | Load a snapshot into the current session |
| `/context-list` | List available snapshots |

## Provider Storage

Snapshots are provider-local so Claude and Codex do not accidentally consume each other's runtime data.

| Provider | Snapshot Directory |
|----------|--------------------|
| Claude | `~/.claude/context-snapshots/` |
| Codex | `~/.codex/context-snapshots/` |

The repo contains separate provider implementations:

| Provider | Plugin Path |
|----------|-------------|
| Claude | `plugins/session-context/` |
| Codex | `codex/plugins/session-context/` |

## Snapshot Content

A context snapshot should capture what another session needs to know without reading the whole project:

```text
# Session Context: <name>
Generated: YYYY-MM-DD HH:MM
Project: <current directory>

## What Was Done
## Files Changed
## Key Decisions
## Open Issues
## Where I Left Off
## Notes for Next Session
```

For API-heavy projects, include endpoint contracts, data models, auth requirements, error formats, and conventions.

## Current Implementation

The current implementation supports manual generation, listing, loading, and sharing. The share command sends a tmux message telling the target session which snapshot to load.

The next useful enhancement is automatic context attachment in `/dispatch`:

```text
/dispatch auth-service "Build the payment webhook handler"

1. Sender checks for an existing context snapshot.
2. Dispatch message includes a context marker.
3. Receiver loads the snapshot before processing the task.
```

## Design Decision

Context sharing is split into `session-context` instead of living inside `session-chat`. The workflow still interoperates with `session-chat` for tmux pane naming and notifications, but snapshot generation, listing, loading, and sharing are a separate installable capability.
