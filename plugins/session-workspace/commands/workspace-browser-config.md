---
description: Render or apply browser MCP configuration for Codex and Claude
argument-hint: "[--config PATH] [--provider codex|claude|all] [--apply] [--json]"
allowed-tools: Bash(bash:*)
---

## Result

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/workspace-browser-config.sh" $ARGUMENTS`

## Instructions

Report the result above. This command is dry-run by default. `--apply` backs
up existing files and refuses a conflicting unmanaged MCP entry.
