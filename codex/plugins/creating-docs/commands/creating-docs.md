---
description: Create or update project documentation using structured templates and validation tools
argument-hint: [topic or file to document]
---

## Instructions

1. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/creating-docs/1.0.3}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/creating-docs"
   ```

2. Read the skill instructions at `$PLUGIN_ROOT/skills/creating-docs/SKILL.md`.
3. Follow the structured process to create or update documentation.
4. If no topic is provided in `$ARGUMENTS`, ask the user what they want to document.
5. After writing or updating docs, run:

   ```bash
   bash "$PLUGIN_ROOT/scripts/check-todos.sh" docs/
   bash "$PLUGIN_ROOT/scripts/validate-links.sh" docs/
   bash "$PLUGIN_ROOT/scripts/check-freshness.sh" docs/ 30
   ```

6. Report the validation results to the user.

## User Request

Topic/context: `$ARGUMENTS`
