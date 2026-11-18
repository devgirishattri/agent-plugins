---
description: Independently verify documentation accuracy against the codebase (report-only, no edits)
argument-hint: "[doc file or directory to review]"
allowed-tools: Read, Glob, Grep, Bash(bash:*), Agent
---

## Instructions

1. Determine the review target from the arguments below. If none is given, default to `docs/`.
2. Delegate to the **doc-reviewer** subagent (`knowledge:doc-reviewer`). Give it the original targets and the absolute installed plugin root resolved from `${CLAUDE_PLUGIN_ROOT}`. It checks references against source. For the validators, use the target directory or the parent of a target file. Run once per distinct directory. Replace both placeholders with resolved literal paths. Strict-v1 requires a directory inside the pane's working directory.
   - `bash "<PLUGIN_ROOT>/scripts/check-todos.sh" "<DOCS_DIR>"`
   - `bash "<PLUGIN_ROOT>/scripts/validate-links.sh" "<DOCS_DIR>"`
   - `bash "<PLUGIN_ROOT>/scripts/check-freshness.sh" "<DOCS_DIR>" 30`
3. This pass is **report-only**. Neither you nor the subagent edits any file.
4. Relay the findings of the subagent to the user. Lead with the overall verdict: ACCURATE or ISSUES FOUND. Then group the findings by file. The findings are stale references, broken links, and missing symbols. If the subagent reports PARTIAL coverage, state which files it did not check.

## User Request

Review target: **$ARGUMENTS**
