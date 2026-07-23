---
description: "[DEPRECATED — superseded by knowledge] Create or update project documentation using structured templates and validation tools"
argument-hint: "[topic or file to document]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Never derive it from the project working directory or embed a cache version.

2. Read the skill instructions at `$PLUGIN_ROOT/skills/creating-docs/SKILL.md`.
3. Follow the structured process to create or update documentation.
4. If no topic is provided in `$ARGUMENTS`, ask the user what they want to document.
5. After writing or updating docs, derive the unique parent directory of every
   changed documentation file. Run the validators once per parent directory;
   use `docs/` only when that is actually the changed document's parent:

   ```bash
   DOCS_DIR="<parent directory of changed doc>"
   bash "$PLUGIN_ROOT/scripts/check-todos.sh" "$DOCS_DIR"
   bash "$PLUGIN_ROOT/scripts/validate-links.sh" "$DOCS_DIR"
   bash "$PLUGIN_ROOT/scripts/check-freshness.sh" "$DOCS_DIR" 30
   ```

6. Delegate an independent, report-only review of the changed docs to a fresh subagent using `$PLUGIN_ROOT/skills/doc-review/SKILL.md`. Give it the target and absolute `PLUGIN_ROOT`, explicitly tell it not to delegate again or edit files, wait for it, and relay the verdict. Only when the runtime has no delegation capability may you review directly; disclose that non-independent fallback.
7. Report the validation and independent-review results to the user.

## User Request

Topic/context: `$ARGUMENTS`
