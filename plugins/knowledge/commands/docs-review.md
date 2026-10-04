---
description: Independently verify documentation accuracy against the codebase (report-only, no edits)
argument-hint: "[doc file or directory to review]"
allowed-tools: Read, Glob, Grep, Bash(bash:*), Agent
---

## Instructions

1. Determine the review target from the arguments below. If none is given, default to `docs/`.
2. Delegate the verification to the **doc-reviewer** subagent through the Agent tool (subagent_type `knowledge:doc-reviewer`). The subagent independently checks that the codebase contains every file path, function, table, endpoint, env var, and cross-link that the target docs reference. It also runs the validation scripts of the plugin:
   - `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh <target>`
   - `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh <target>`
   - `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh <target> 30`
3. This pass is **report-only**. Neither you nor the subagent edits any file.
4. Relay the findings of the subagent to the user. Lead with the overall verdict: ACCURATE or ISSUES FOUND. Then group the findings by file. The findings are stale references, broken links, and missing symbols. If the subagent reports PARTIAL coverage, state which files it did not check.

## User Request

Review target: **$ARGUMENTS**
