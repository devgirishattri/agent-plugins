---
description: Create or update project documentation using structured templates, reference-based notation, and validation tools
argument-hint: [topic or file to document]
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(bash:*)
---

## Skill Instructions

!`cat ${CLAUDE_PLUGIN_ROOT}/skills/creating-docs/SKILL.md | sed '1,/^---$/{ /^---$/!d; d; }'`

## User Request

Topic/context: **$ARGUMENTS**

## Instructions

1. Follow the skill instructions above to create or update documentation
2. If $ARGUMENTS is empty, ask the user what they want to document
3. After writing docs, run the validation scripts referenced in the skill using Bash
4. Report validation results to the user
