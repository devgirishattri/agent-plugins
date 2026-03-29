# Cross-Project Context Sharing

**Date**: 2026-03-29
**Status**: Draft
**Related**: `TODO.md`

## Overview

A mechanism for Claude sessions working in different project directories to share project knowledge — API contracts, schemas, conventions, and architecture summaries. When an orchestrator dispatches a task to a session in another repo, that session often lacks the context needed to do the work well.

## Problem

```
Session A (ProjectA/api)              Session B (ProjectB/auth)
    |                                       |
    |-- /dispatch B "Build the client       |
    |   for our payment endpoint"           |
    |                                       |
    |   B doesn't know:                     |
    |   - What endpoints exist              |
    |   - Request/response format           |
    |   - Auth requirements                 |
    |   - Error handling conventions        |
```

Session B has to ask Session A for details, creating back-and-forth that slows the workflow. The context should be available upfront.

## Proposed Solution

### Context Snapshots

Each project can generate a **context snapshot** — a concise summary of its key interfaces, stored as a shareable file. Other sessions can load it before starting work.

### Commands

| Command | Purpose |
|---------|---------|
| `/context-generate` | Generate a context snapshot for the current project |
| `/context-share <session>` | Send this project's snapshot to another session |
| `/context-load <project>` | Load a shared snapshot into current session's context |
| `/context-list` | List available snapshots |

### Snapshot Content

A context snapshot captures what an outsider needs to know:

```
# ProjectA Context Snapshot
Generated: 2026-03-29

## API Endpoints
POST /api/v2/payments — Create payment (auth: JWT, role: merchant)
GET  /api/v2/payments/:id — Get payment status (auth: JWT)
...

## Data Models
payments: id, amount, currency, status, merchant_id, created_at
merchants: id, name, api_key_hash, webhook_url

## Auth Pattern
JWT RS256, 1h expiry, fields: sub, role, org_id
Middleware: withAuth() in src/middleware/auth.ts

## Error Format
{ error: { code: string, message: string, details?: object } }

## Conventions
- All endpoints return { data: T } envelope
- Pagination: ?page=1&limit=20, response includes { meta: { total, page, limit } }
- Timestamps: ISO 8601 UTC
```

### Storage

```
~/.claude/context-snapshots/
├── project-a.md          # Generated snapshot
├── project-b.md          # Generated snapshot
└── project-c.md          # Generated snapshot
```

Stored in `~/.claude/` (user-level, not project-level) so snapshots are accessible from any project directory.

### Generation Strategy

The `/context-generate` command should:

1. Read the project's CLAUDE.md for high-level context
2. Scan for API route definitions (Express routes, Laravel routes, FastAPI, etc.)
3. Scan for database schema (Prisma, migrations, models)
4. Read existing documentation in `docs/`
5. Identify auth patterns, error handling conventions
6. Produce a concise snapshot (under 500 lines)

This can be a skill that guides Claude through the generation, not a deterministic script — each project is different.

### Integration with session-chat

When `/dispatch` sends a task to another session, it could **automatically attach** the sender's context snapshot:

```
/dispatch auth-service "Build the payment webhook handler"

→ Checks if ~/.claude/context-snapshots/project-a.md exists
→ Sends: [from:orchestrator] [context:project-a] Build the payment webhook handler
→ auth-service loads the snapshot before processing the task
```

This is the key integration — context sharing happens automatically during dispatch, not as a manual step.

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│ Plugin: context-share (or addition to session-chat)     │
│                                                         │
│ Commands:                                               │
│   /context-generate  → skill-guided snapshot creation   │
│   /context-share     → send snapshot via tmux/file      │
│   /context-load      → read snapshot into session       │
│   /context-list      → list available snapshots         │
│                                                         │
│ Storage:                                                │
│   ~/.claude/context-snapshots/<project-name>.md          │
│                                                         │
│ Integration:                                            │
│   dispatch-to-session.sh → auto-attach context          │
│   detect-incoming-message.sh → auto-load context        │
└─────────────────────────────────────────────────────────┘
```

## Implementation Approach

### Phase 1: Manual context generation and sharing
- `/context-generate` — skill that guides Claude through snapshot creation
- `/context-share <session>` — sends the snapshot file to another session via `/send`
- `/context-load` — reads a received snapshot

### Phase 2: Automatic context attachment
- `/dispatch` auto-attaches sender's snapshot when dispatching cross-project
- Receiving session auto-loads the attached context before processing

### Phase 3: Smart generation
- Auto-detect project type (Node, Laravel, Python, etc.)
- Framework-specific scanning (Express routes, Prisma schema, etc.)
- Incremental updates (only regenerate changed sections)

## Decision: Plugin or Feature?

**Recommendation: Addition to session-chat plugin**

The context sharing is tightly coupled with the dispatch workflow. Adding it as commands/skills within session-chat keeps the cross-session communication unified in one plugin rather than splitting across two.

## Related Documents

- `TODO.md` — Tracks all planned plugin work
