---
description: Create or update project documentation using structured templates, reference-based notation, and validation tools
argument-hint: [topic or file to document]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(bash:*)
---

## Documentation Process

Read the full instructions at `${CLAUDE_PLUGIN_ROOT}/skills/creating-docs/SKILL.md` and follow them to create or update documentation.

Topic/context from the user: **$ARGUMENTS**

## Validation Scripts

After writing or updating docs, run these validation scripts:

### Check for embedded TODOs
!`echo "bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh docs/"`

### Validate cross-references
!`echo "bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh docs/"`

### Check doc freshness
!`echo "bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh docs/ 30"`

## Instructions

1. Use the Read tool to load the full skill instructions from the path above
2. Follow the structured process in the skill to create/update documentation
3. After writing docs, run the validation scripts listed above using Bash
4. Report validation results to the user
