---
name: creating-docs
description: This skill should be used when creating new documentation files or updating existing ones, especially when documenting system architecture, features, integrations, workflows, or technical decisions. Also use when asked to "document", "write docs for", or "create a doc about" any system component. Trigger this skill whenever the user wants to capture knowledge about how something works, even if they don't explicitly say "documentation" — phrases like "explain how X works and save it", "write up the auth flow", or "I need a reference for the API" all qualify.
user-invocable: true
---

# Creating Documentation

A structured process for creating and updating project documentation. Documents use **reference-based notation** (function names, table names, file paths) rather than code snippets or line numbers, because references stay accurate as code evolves while line numbers and copied code rot immediately.

## Process

1. **Check for project guidelines** — Look for existing documentation guidelines in the project (e.g., `docs/DOCUMENTATION_GUIDELINES.md`, `CONTRIBUTING.md`). If the project has its own doc standards, follow those and use this skill only to fill gaps.
2. **Gather information** — Read all relevant source files, check for existing docs, and map how components connect. Build a mental inventory of file paths, functions, tables, endpoints, env vars, and external services involved. Do not start writing until the full picture is understood — docs written from partial understanding mislead readers.
3. **Choose document type** — Identify which sections apply (see `references/DOCUMENT_TYPES.md`). Most docs blend categories — pick the sections that serve the reader, not force a single type.
4. **Write using the template** — Fill in the template structure below. If updating an existing doc, read it first, change only affected sections, and update the Date in metadata.
5. **Add Key References** — For docs referencing 5+ files/functions/tables, add a summary table at the end (see format below). Short docs that only touch 2-3 files can skip this.
6. **Log TODOs and issues** — If incomplete features, bugs, or planned work are discovered during research, add them to `docs/TODO.md` or `docs/ISSUES.md` (create these files if they don't exist). Never embed TODOs or issues in the documentation itself. See `references/TODO_TRACKING.md` for format.
7. **Check size and split if needed** — After writing, check if the doc should be split (see `references/SPLITTING_GUIDE.md`). Proactively suggest splitting to the user if the doc covers 3+ distinct subsystems at 80+ lines each.
8. **Add diagrams** — Include Mermaid diagrams where relationships are hard to follow in prose. See `references/DIAGRAMS_GUIDE.md` for types and examples.
9. **Cross-reference** — Link to related docs and update them if the new doc changes the picture.

## Naming Convention

**All documentation filenames MUST use UPPER_CASE with underscores** (e.g., `AUTH_OVERVIEW.md`, `API_REFERENCE.md`, `DATABASE_SCHEMA.md`). This makes docs visually distinct from code files and easy to spot in directory listings.

- Good: `AUTH_OVERVIEW.md`, `API_REFERENCE.md`, `DEPLOYMENT_GUIDE.md`
- Bad: `auth-overview.md`, `api_reference.md`, `deployment-guide.md`

Tracker files follow this convention: `TODO.md`, `ISSUES.md`.

## Where to Save

Place docs where readers will find them:
- `docs/` directory if the project has one (most common)
- Alongside the code they describe (e.g., `src/auth/AUTH.md`) for module-specific docs
- Project root for high-level architecture docs
- If unsure, ask the user

## Document Template

The metadata header (Date/Status/Related) is recommended for discoverability but not mandatory — match the style of existing docs in the project.

```
# [Document Title]

**Date**: YYYY-MM-DD
**Status**: Draft | Active | Deprecated
**Related**: `AUTH_OVERVIEW.md`, `API_REFERENCE.md`

## Overview

[1-3 sentences: What this document covers and why it exists]

## [Body Sections]

[Pick sections from Document Types based on what the reader needs]

## Key References

[Include for docs with 5+ referenced files/functions/tables]

## Related Documents

[Links to related docs with brief description of relationship]
```

## Reference Notation

Use reference names instead of line numbers. Line numbers shift with every edit; function names and file paths are stable and greppable.

| Element | Format |
|---------|--------|
| Functions | `functionName()` |
| Files | `path/from/root` |
| Tables | `table_name` |
| Columns | `table.column` or `column` in context |
| Endpoints | `METHOD /path` |
| Env vars | `VAR_NAME` |

**Code snippets** are valuable when they help the reader understand the actual interface — JSON request/response examples for APIs, SQL schema definitions, config formats, query key structures, or algorithms that are unclear in prose. Keep snippets focused on the interface, not implementation internals.

## Key References Table Format

Group entries by file for scannability. For large docs (20+ references), include only primary functions — skip internal helpers unless called from outside the module.

| Type | Name | Location |
|------|------|----------|

## Updating Existing Documents

1. Read the entire existing document first
2. Identify what changed — new functions, removed tables, modified flows
3. Update only affected sections — do not rewrite unchanged content
4. Update the Date in metadata
5. Verify Key References — add new ones, remove stale ones
6. Check Related Documents — update cross-references if scope changed

## Validation Tools

This skill bundles three scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/` for verifying doc health. Run them after writing or updating docs.

### check-todos.sh

Scans doc files for embedded TODO/FIXME/HACK markers that should be in the dedicated tracker files instead. Run this after every doc creation or update.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh docs/
```

### validate-links.sh

Checks that all cross-references in docs actually point to existing files. Catches stale links after renames or deletions.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh docs/
```

### check-freshness.sh

Compares doc modification dates against the code files they reference using git history. Flags docs not updated since their referenced code changed.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh docs/ 30
```

Arguments: `[docs-directory]` and `[days-threshold]` (default: 30 days).

Run the link validator after every doc creation/update. Run the freshness checker periodically or when the user asks to audit documentation health.

## Additional Resources

### Reference Files

For detailed guidance on specific topics, consult:

- **`references/DOCUMENT_TYPES.md`** — Document type sections (API Reference, System/Architecture, Module/Feature, Integration, Plan/Design) and optional sections
- **`references/DIAGRAMS_GUIDE.md`** — Mermaid diagram types, when to include them, and examples
- **`references/TODO_TRACKING.md`** — TODO.md and ISSUES.md format, when to create entries, and resolution workflow
- **`references/SPLITTING_GUIDE.md`** — When to split docs, when long is fine, and how to split by concept
