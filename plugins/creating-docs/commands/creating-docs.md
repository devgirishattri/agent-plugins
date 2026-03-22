---
description: Create or update project documentation using structured templates, reference-based notation, and validation tools
argument-hint: [topic or file to document]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(bash:*)
---

## Instructions

1. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/creating-docs/SKILL.md` using the Read tool
2. Follow the structured process to create or update documentation
3. If no topic is provided below, ask the user what they want to document
4. After writing docs, run the validation scripts referenced in the skill using Bash
5. Report validation results to the user

## User Request

Topic/context: **$ARGUMENTS**

## Validation Scripts

Run these after writing or updating docs:

- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh docs/`
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh docs/`
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh docs/ 30`
