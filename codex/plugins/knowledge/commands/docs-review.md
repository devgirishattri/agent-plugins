---
description: Independently verify documentation accuracy against the codebase and run the validation scripts (report-only, no edits)
argument-hint: "[doc file or docs directory to review]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Never derive it from the project working directory or embed a cache version.

2. Read the skill instructions at `$PLUGIN_ROOT/skills/docs-review/SKILL.md`.
3. Determine the review target from `$ARGUMENTS`; if none is provided, default to `docs/`.
4. Delegate the skill's worker process to a fresh read-only subagent with isolated/no inherited conversation context when supported. Give it only the target, absolute `PLUGIN_ROOT`, and worker instructions; explicitly identify it as the independent worker so it does not delegate again, wait for it, and relay its report. If and only if subagent delegation is unavailable in this runtime, perform the worker process directly and disclose that the fallback was not independent.
5. The independent worker checks every referenced file path, function, table,
   endpoint, env var, and cross-link against the real codebase. For a file
   target, derive its parent directory; for a directory target, use it directly.
   Run the scripts once per unique target directory (not a hard-coded `docs/`):

   ```bash
   DOCS_DIR="<target directory or parent of target file>"
   bash "$PLUGIN_ROOT/scripts/validate-links.sh" "$DOCS_DIR"
   bash "$PLUGIN_ROOT/scripts/check-todos.sh" "$DOCS_DIR"
   bash "$PLUGIN_ROOT/scripts/check-freshness.sh" "$DOCS_DIR" 30
   ```

6. Report the worker's structured verdict (ACCURATE / ISSUES FOUND) with broken references, stale items, script results, and suggested fixes. Neither the caller nor worker may edit files — this command is report-only.

## User Request

Target: `$ARGUMENTS`
