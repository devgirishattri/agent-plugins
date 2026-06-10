---
description: Independently verify documentation accuracy against the codebase and run the validation scripts (report-only, no edits)
argument-hint: [doc file or docs directory to review]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/creating-docs/1.1.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/creating-docs"
   ```

2. Read the skill instructions at `$PLUGIN_ROOT/skills/doc-review/SKILL.md`.
3. Determine the review target from `$ARGUMENTS`; if none is provided, default to `docs/`.
4. Follow the skill's verification pass: check every referenced file path, function, table, endpoint, env var, and cross-link against the real codebase.
5. Run the three validation scripts against the target docs directory:

   ```bash
   bash "$PLUGIN_ROOT/scripts/validate-links.sh" docs/
   bash "$PLUGIN_ROOT/scripts/check-todos.sh" docs/
   bash "$PLUGIN_ROOT/scripts/check-freshness.sh" docs/ 30
   ```

6. Report the structured verdict (ACCURATE / ISSUES FOUND) with broken references, stale items, script results, and suggested fixes. Do NOT edit any files — this command is report-only.

## User Request

Target: `$ARGUMENTS`
