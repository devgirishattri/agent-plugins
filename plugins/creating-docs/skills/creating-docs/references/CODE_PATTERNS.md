# Code Patterns Documentation

Guide for documenting recurring code patterns, conventions, and architectural decisions. Pattern docs capture *how things should be done* — the knowledge that lives in senior developers' heads and gets lost when they leave.

## When to Create Pattern Docs

- A pattern appears in 3+ places across the codebase
- New developers keep asking "how do I do X here?"
- Code reviews repeatedly catch the same convention violations
- A non-obvious approach was chosen for good reasons that need to be recorded

## Pattern Document Structure

Each pattern doc should follow this structure:

```
# PATTERN_NAME.md

**Date**: YYYY-MM-DD
**Status**: Active | Deprecated | Superseded by [OTHER_PATTERN.md]
**Related**: [related pattern or module documentation, if any]

## Overview

[1-2 sentences: what this pattern is and when to use it]

## Pattern

[Focused code example, 5-15 lines, showing the canonical way to do it]

## When to Use

[Bullet list of scenarios where this pattern applies]

## Anti-patterns

[What NOT to do, with brief explanation of why]

## Examples in Codebase

[References to real files that demonstrate this pattern]
```

## Common Pattern Categories

### Error Handling

Document how the codebase handles errors consistently:
- Error wrapping and propagation
- Custom error types and when to use them
- Retry logic and circuit breakers
- User-facing error messages vs. internal logging

### Authentication / Authorization

Document how to protect resources:
- Middleware wiring for new endpoints
- Role and permission checks
- Token handling patterns
- Service-to-service auth

### Data Access

Document how the codebase interacts with data stores:
- Repository or service layer patterns
- Query builders vs. raw queries
- Transaction handling
- Connection management and pooling

### Testing

Document how to write tests that fit the project:
- Test file naming and location
- Fixture and factory setup
- Mocking and stubbing conventions
- Integration test database handling
- Assertion styles and custom matchers

### Configuration / Environment

Document how new configuration is added:
- Environment variable registration
- Config validation at startup
- Feature flags and toggles
- Secrets management

### API Conventions

Document how to build consistent APIs:
- Request/response envelope format
- Pagination patterns
- Filtering and sorting conventions
- Versioning approach

## Writing Effective Pattern Examples

### Keep Examples Focused

Show only the pattern, not surrounding boilerplate:

**Good** — shows the error handling pattern:
```
const result = await userService.findById(id);
if (!result) {
  throw new NotFoundError("User", id);
}
return result;
```

**Bad** — buries the pattern in boilerplate:
```
import { Router } from 'express';
import { userService } from '../services';
import { NotFoundError } from '../errors';
import { validate } from '../middleware';
import { getUserSchema } from '../schemas';

const router = Router();

router.get('/:id', validate(getUserSchema), async (req, res, next) => {
  try {
    const result = await userService.findById(req.params.id);
    if (!result) {
      throw new NotFoundError("User", req.params.id);
    }
    res.json({ data: result });
  } catch (err) {
    next(err);
  }
});
```

### Show the Anti-pattern Too

Contrast helps developers recognize what to avoid:

```
## Anti-patterns

### Swallowing errors silently
try {
  await service.process(data);
} catch (e) {
  // Don't do this — failures disappear
}

### Why: Silent failures cause data inconsistencies that surface
hours later with no trail back to the root cause.
```

### Reference Real Files

Point to actual implementations so developers can see the pattern in full context:

```
## Examples in Codebase

| File | Pattern Usage |
|------|--------------|
| `src/services/USER_SERVICE.ts` | `findById()` with NotFoundError |
| `src/services/ORDER_SERVICE.ts` | `create()` with transaction wrapping |
| `src/middleware/AUTH.ts` | Role-based access pattern |
```

## Architecture Decision Records (ADR)

ADRs capture *why* a decision was made. They prevent:
- Re-litigating settled decisions
- New developers undoing intentional choices
- Knowledge loss when team members leave

### ADR Structure

```
# ADR_DECISION_NAME.md

**Date**: YYYY-MM-DD
**Status**: Accepted
**Deciders**: [who was involved]

## Context

[What situation or problem prompted this decision.
Include constraints, requirements, and any pressure that shaped it.]

## Decision

[What was decided. Be specific — name the technology,
pattern, or approach chosen.]

## Alternatives Considered

### [Alternative 1]
- Pros: ...
- Cons: ...
- Why rejected: ...

### [Alternative 2]
- Pros: ...
- Cons: ...
- Why rejected: ...

## Consequences

### Positive
- [benefit 1]
- [benefit 2]

### Negative (accepted trade-offs)
- [trade-off 1]
- [trade-off 2]
```

### When to Write an ADR

- Choosing a database, framework, or major library
- Selecting an architectural pattern (monolith vs. microservices, REST vs. GraphQL)
- Establishing a convention that affects multiple modules
- Making a performance/security/maintainability trade-off
- Deciding NOT to do something (these are often the most valuable ADRs)

### ADR Naming

Follow the UPPER_CASE convention: `ADR_AUTH_JWT.md`, `ADR_DATABASE_POSTGRES.md`, `ADR_MONOREPO_STRUCTURE.md`.

## Organizing Pattern Docs

Place pattern docs where they make sense:

- `docs/patterns/` — Cross-cutting patterns (error handling, testing, config)
- `docs/adr/` — Architecture decision records
- `src/module/PATTERNS.md` — Module-specific patterns (alongside the code)

For projects with 10+ patterns, create a `docs/patterns/INDEX.md` that lists all patterns grouped by category.
