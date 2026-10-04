---
name: docs-create
description: This skill should be used when creating new documentation files or updating existing ones, especially when documenting system architecture, features, integrations, workflows, or technical decisions. Also use when asked to "document", "write docs for", or "create a doc about" any system component. Trigger this skill whenever the user wants to capture knowledge about how something works, even if they don't explicitly say "documentation" — phrases like "explain how X works and save it", "write up the auth flow", or "I need a reference for the API" all qualify.
user-invocable: true
---

# Creating Documentation

This skill is a structured process for creating and updating project documentation.

- Describe what exists with **reference-based notation** (function names, table names, file paths). References stay accurate as code evolves. Line numbers and copied code go stale immediately.
- Show how to do things with **focused code examples**. Use them for recurring patterns, conventions, and interfaces that developers need to copy and adapt.

Distill can compose this workflow after the user approves its exact document patches in a combined batch. No additional skill invocation is needed. Keep the role preflight, the validation, and the independent review below. Include discovered tracker changes in the batch before you apply them.

## Process

0. **Reviewer-role preflight (run first).**
   1. Resolve the repository root in a SEPARATE read-only step. Run `git rev-parse --show-toplevel`. If the directory is not a git repository, use the current working directory.
   2. Invoke the preflight as exactly one literal Bash segment. Substitute the resolved absolute path yourself. Use no `export`, `env`, or assignment prefix. Use no command substitution. Do not chain, pipe, or redirect:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/docs-write.sh" --repo "<REPO_ROOT>"
   ```
   3. Read the exit code. Exit `0` means proceed. Any non-zero exit means **stop immediately**. This includes `6` with stderr `reviewer role: docs writes refused`. It also includes an unresolved fleet identity that asks you to set `KNOWLEDGE_PANE_NAME`.
   4. On a stop, do not read further. Do not create, edit, or delete any file (including `TODO.md` and `ISSUES.md`). Relay the script's stderr line to the user as the reason.

   The preflight gates every write this skill performs, including the TODO/ISSUES maintenance in step 6.
1. **Check for project guidelines.** Look for existing documentation guidelines in the project (for example `docs/DOCUMENTATION_GUIDELINES.md` or `CONTRIBUTING.md`). If the project has its own doc standards, follow them. Use this skill only to fill gaps.
2. **Gather information.** Read all relevant source files. Check for existing docs. Map how components connect. Build an inventory of the file paths, functions, tables, endpoints, env vars, and external services involved. Do not start writing until you understand the full picture. Docs written from partial understanding mislead readers.
   Docs should be current-facing. Keep historical material only when it explains an active decision, constraint, migration, or provenance that readers still need.
3. **Choose the document type.** Identify which sections apply (see `references/DOCUMENT_TYPES.md`). Most docs blend categories. Pick the sections that serve the reader. Do not force a single type.
4. **Write using the template.** Fill in the template structure below. To update an existing doc, read it first. Change only the affected sections. Update the Date in metadata.
5. **Add Key References.** If the doc references 5 or more files, functions, or tables, add a summary table at the end (format below). A short doc that touches only 2-3 files can skip this.
6. **Log TODOs and issues.** If research finds incomplete features, bugs, or planned work, add them to `docs/TODO.md` or `docs/ISSUES.md`. Create these files if they do not exist. Never embed TODOs or issues in the documentation itself. See `references/TODO_TRACKING.md` for the format.
7. **Check size and split if needed.** After writing, check whether to split the doc (see `references/SPLITTING_GUIDE.md`). If the doc covers 3 or more distinct subsystems at 80 or more lines each, suggest splitting to the user.
8. **Add diagrams.** Include Mermaid diagrams where prose cannot show a relationship clearly. See `references/DIAGRAMS_GUIDE.md` for types and examples.
9. **Cross-reference.** Link to related docs. Update them if the new doc changes the picture.
10. **Independent review.** After every docs write or edit, including a single-file change, run a fresh, read-only accuracy review. Complete it before you report the work done. The writer cannot see its own stale references.
    - **Preferred:** delegate to the **doc-reviewer** subagent through the Agent tool (`subagent_type: knowledge:doc-reviewer`). The subagent independently verifies that every referenced path, function, table, endpoint, env var, and cross-link exists in the codebase. It re-runs the validation scripts once per unique parent directory of the docs you touched (see Validation Tools).
    - **Fallback (only when the Agent tool is unavailable):** perform the review inline yourself. Re-read each doc you changed. Verify every reference against the codebase. Re-run the validators.
    - **Repeat after fixes:** if the review finds issues, fix the docs. Then run the independent review again on the changed docs. Do not report the documentation as complete until an independent review has passed.

**Report the result.** When the work ends, lead with the state: `complete` (the independent review passed) or `blocked` (the preflight or the review stopped the work). List the files written. For a blocked state, give the reason and the exact next action.

## Naming Convention

Name new project-specific documentation files with semantic `snake_case.md` names (for example `auth_overview.md`, `api_reference.md`, `database_schema.md`). If the project defines another convention, use that convention. Keep dates and datetimes in document metadata, not in filenames. Preserve conventional community filenames such as `README.md`, `CONTRIBUTING.md`, `SECURITY.md`, and `CHANGELOG.md`. Preserve existing repository conventions.

- Good: `auth_overview.md`, `api_reference.md`, `deployment_guide.md`
- Bad: `AUTH_OVERVIEW.md`, `auth-overview.md`, `deployment-2026-07-23.md`

Tracker files keep their conventional uppercase names: `TODO.md`, `ISSUES.md`.

## Where to Save

Place docs where readers will find them:
- `docs/` directory if the project has one (most common)
- Alongside the code they describe (e.g., `src/auth/AUTH.md`) for module-specific docs
- Project root for high-level architecture docs
- If unsure, ask the user

## Document Template

The metadata header (Date/Status/Related) is recommended for discoverability. It is not mandatory. Match the style of existing docs in the project.

```
# [Document Title]

**Date**: YYYY-MM-DD
**Status**: Draft | Active | Deprecated
**Related**: [related documentation, if any]

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

Use reference names instead of line numbers. Line numbers shift with every edit. Function names and file paths are stable and greppable.

| Element | Format |
|---------|--------|
| Functions | `functionName()` |
| Files | `path/from/root` |
| Tables | `table_name` |
| Columns | `table.column` or `column` in context |
| Endpoints | `METHOD /path` |
| Env vars | `VAR_NAME` |

**When to use code examples:**
- **Interfaces** — JSON request/response examples for APIs, SQL schema definitions, config formats
- **Recurring patterns** — Error handling, auth middleware, data access, testing setup (see `references/CODE_PATTERNS.md`)
- **Conventions** — How the codebase structures things that new developers need to follow

Keep examples focused and short (5-15 lines). Show the pattern, not the full implementation. Use references to describe *what* exists. Use code examples to show *how* to do things.

## Key References Table Format

Group entries by file for scannability. For a large doc (20 or more references), list only primary functions. Skip internal helpers unless code outside the module calls them.

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

This skill bundles three scripts in `${CLAUDE_PLUGIN_ROOT}/scripts/` to verify doc health. Run them after you write or update docs.

**Target the actual location of the docs.** Docs can live at the project root, under `docs/`, or next to a module (for example `src/api/README.md`). Derive the parent directory of each doc you created or edited. Run each validator **once per unique parent directory**. The `docs/` shown below is only an example, not a fixed path. Every script accepts any directory argument (default `.`).

### check-todos.sh

Scans doc files for embedded TODO/FIXME/HACK markers. These markers belong in the dedicated tracker files. Run this script after every doc creation or update.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh docs/
```

### validate-links.sh

Checks that Markdown `.md` cross-references (inline links and `**Related**:` header refs) point to existing files. It catches stale links after renames or deletions.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh docs/
```

### check-freshness.sh

Compares doc modification dates against the code files that the docs reference, using git history. It flags docs that nobody updated since their referenced code changed.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh docs/ 30
```

Arguments: `[docs-directory]` and `[days-threshold]` (default: 30 days).

Run the link validator after every doc creation or update. Run the freshness checker periodically, or when the user asks to audit documentation health.

## Additional Resources

### Reference Files

For detailed guidance on specific topics, consult:

- **`references/DOCUMENT_TYPES.md`** — Document type sections (API Reference, System/Architecture, Module/Feature, Integration, Plan/Design, Code Patterns, ADR) and optional sections
- **`references/CODE_PATTERNS.md`** — How to document recurring code patterns, conventions, and architectural decisions
- **`references/DIAGRAMS_GUIDE.md`** — Mermaid diagram types, when to include them, and examples
- **`references/TODO_TRACKING.md`** — TODO.md and ISSUES.md format, when to create entries, and resolution workflow
- **`references/SPLITTING_GUIDE.md`** — When to split docs, when long is fine, and how to split by concept
