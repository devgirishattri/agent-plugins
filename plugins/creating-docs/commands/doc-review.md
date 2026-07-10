---
description: Independently verify documentation accuracy against the codebase (report-only, no edits)
argument-hint: "[doc file or directory to review]"
allowed-tools: Read, Glob, Grep, Bash(bash:*), Agent
---

## Instructions

1. Determine the review target from the arguments below; default to `docs/` if none given.
2. Delegate the verification to the **doc-reviewer** subagent via the Agent tool (subagent_type `creating-docs:doc-reviewer`). It independently checks that every referenced file path, function, table, endpoint, env var, and cross-link in the target docs actually exists in the codebase, and runs the plugin's validation scripts:
   - `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh <target>`
   - `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh <target>`
   - `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh <target> 30`
3. This is a **report-only** pass: neither you nor the subagent edits any files. Relay the subagent's findings (stale references, broken links, missing symbols) to the user, grouped by file, with an overall ACCURATE / ISSUES FOUND verdict.

## User Request

Review target: **$ARGUMENTS**
