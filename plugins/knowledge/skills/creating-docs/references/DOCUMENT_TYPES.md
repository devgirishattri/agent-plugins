# Document Types

Pick the sections that fit the document. Most real docs blend these categories.

## API Reference

For endpoint-by-endpoint documentation. Each endpoint should include enough detail for a developer to integrate without reading the source code.

**Per-endpoint structure:**
- **Endpoint** — `METHOD /path`
- **Description** — What it does, in one line
- **Access** — Auth requirements, role, rate limits
- **Files** — Types, validator, service, controller, route (helps developers find the implementation)
- **Flow** — Numbered steps showing what happens server-side
- **Request** — Body fields with types, required/optional, constraints
- **Response** — JSON example with field descriptions
- **Errors** — Status codes and when they occur
- **Notes** — Edge cases, gotchas, related behavior

For docs with many endpoints, start with a summary table (`Method | Endpoint | Description`), then detail each one. Add a **Table of Contents** for docs with 10+ endpoints.

## System / Architecture

| Section | Purpose |
|---------|---------|
| **Architecture** | Components, layers, how they connect |
| **Database Schema** | Tables, relationships, key columns |
| **API Endpoints** | `Method | Path | Auth | Description` summary table |
| **Data Flow** | Step-by-step: "`X` calls `Y()`, which queries `Z` table" |
| **Gotchas & Edge Cases** | Known issues, non-obvious behavior, constraints |

## Module / Feature

| Section | Purpose |
|---------|---------|
| **How It Works** | High-level behavior description |
| **Components** | Files and their responsibilities |
| **Database** | Tables, key columns, relationships |
| **Lifecycle** | State transitions, status progressions |
| **API Routes** | Endpoints table |
| **Business Rules** | Domain logic, validation, constraints |

## Integration

| Section | Purpose |
|---------|---------|
| **External Service** | Service name, purpose, API version |
| **Setup** | Configuration steps, env vars, credentials (names not values) |
| **Authentication** | How auth works — token names, not values |
| **Sync Pattern** | How data flows between systems |
| **Data Mapping** | `Source field -> Destination column` table (key mappings only) |
| **Error Handling** | Failure handling, retry patterns |
| **Troubleshooting** | Common errors and their fixes |

## Code Patterns

For documenting recurring patterns and conventions that developers need to follow. See `references/CODE_PATTERNS.md` for detailed guidance.

| Section | Purpose |
|---------|---------|
| **Pattern Name** | Short, descriptive name |
| **When to Use** | Scenarios where this pattern applies |
| **Example** | Focused code example (5-15 lines) showing the pattern |
| **Anti-patterns** | What NOT to do, with brief explanation |
| **Related Patterns** | Links to related patterns |

## Architecture Decision Record (ADR)

For capturing *why* decisions were made — not just what exists. ADRs prevent re-litigating settled decisions and give new team members context.

| Section | Purpose |
|---------|---------|
| **Title** | Short decision name (e.g., "Use PostgreSQL for user data") |
| **Status** | Proposed / Accepted / Deprecated / Superseded by [ADR_NAME.md] |
| **Context** | What situation or problem prompted this decision |
| **Decision** | What was decided and why |
| **Alternatives Considered** | Other options evaluated, with reasons for rejection |
| **Consequences** | Trade-offs accepted, both positive and negative |

Name ADR files by topic: `ADR_AUTH_JWT.md`, `ADR_DATABASE_CHOICE.md` — not by number.

## Plan / Design

| Section | Purpose |
|---------|---------|
| **Goal** | What this plan achieves |
| **Requirements** | Numbered list |
| **Proposed Changes** | Schema changes, new endpoints, modified functions |
| **Migration Steps** | Ordered implementation steps |
| **Risks & Mitigations** | What could go wrong, how to handle it |

## Optional Sections

Include these when they add value:

- **Table of Contents** — For docs over ~150 lines with multiple sections
- **Troubleshooting** — Common errors and their solutions (especially useful for integrations)
- **Environment Configuration** — Env vars with descriptions (names only, never values)
- **Cron Jobs / Background Tasks** — Schedule, purpose, what they do
- **Email / Notification Templates** — Template name, recipient, trigger

Do NOT add TODO or issue sections to documentation files — use the dedicated tracker files instead.
