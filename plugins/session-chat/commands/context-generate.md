---
description: Generate a context snapshot of the current project for sharing with other sessions
argument-hint: [project-name]
allowed-tools: Read, Glob, Grep, Bash(bash:*)
---

## Instructions

Generate a concise context snapshot of the current project that another session can use to understand the project's interfaces, conventions, and architecture.

1. **Determine project name**: Use $ARGUMENTS if provided, otherwise derive from the current directory name (last path component, lowercase, hyphens for spaces).

2. **Scan the project** — Read these sources (skip any that don't exist):
   - `CLAUDE.md` — project guidelines and conventions
   - `README.md` — project overview
   - Route/endpoint definitions (Express, Laravel, FastAPI, Django, etc.)
   - Database schema (Prisma schema, migrations, models)
   - API documentation in `docs/`
   - Package manifests (`package.json`, `composer.json`, `pyproject.toml`, `Cargo.toml`)
   - Auth/middleware patterns
   - Environment variable usage (`.env.example`)

3. **Generate the snapshot** with these sections (include only what's relevant):

   ```
   # <Project Name> Context Snapshot
   Generated: YYYY-MM-DD

   ## Overview
   [1-2 sentences: what this project does]

   ## Tech Stack
   [Language, framework, database, key dependencies]

   ## API Endpoints
   [Method, path, auth, description — table format]

   ## Data Models
   [Key tables/models with important fields]

   ## Auth Pattern
   [How auth works: token type, middleware, key fields]

   ## Error Format
   [Standard error response shape]

   ## Conventions
   [Coding patterns, naming, file structure conventions]

   ## Environment Variables
   [Key env vars needed, from .env.example]
   ```

4. **Save the snapshot**: Write it to a temp file, then run:
   ```
   bash ${CLAUDE_PLUGIN_ROOT}/scripts/save-context.sh "<project-name>" "<temp-file>"
   ```

5. **Report**: "Context snapshot for '<project-name>' generated. Share it with `/context-share <session> <project-name>`."

Keep the snapshot **concise** — under 300 lines. Focus on interfaces (what other sessions need to know), not implementation details.
