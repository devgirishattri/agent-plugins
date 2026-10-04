---
description: Create or update project documentation using structured templates, reference-based notation, and validation tools
argument-hint: "[topic or file to document]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(bash:*), Agent
disable-model-invocation: true
---

## Instructions

1. **Reviewer-role preflight. Run it FIRST, before any other step. Stop on non-zero.**
   1. Resolve the repository root in a SEPARATE read-only step. Run `git rev-parse --show-toplevel`. If the directory is not a git repository, use the current working directory.
   2. Invoke the preflight as exactly one literal Bash segment. Substitute the resolved absolute path yourself. Use no `export`, `env`, or assignment prefix. Use no command substitution. Do not chain, pipe, or redirect:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/docs-write.sh" --repo "<REPO_ROOT>"
   ```
   - Exit `0`: proceed to step 2.
   - Any non-zero exit (for example `6` — `reviewer role: docs writes refused`, or an unresolved fleet identity): **stop immediately.** Do not read the skill. Do not write or edit any file. Relay the script's stderr line to the user verbatim as the reason that no docs were written.
2. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/docs-create/SKILL.md` with the Read tool.
3. Follow the structured process to create or update documentation.
4. If the request below has no topic, ask the user what to document.
5. After you write docs, run the validation scripts with Bash. Target the **parent directory of each doc you actually created or edited**. A doc can live at the project root, under `docs/`, or next to a module (for example `src/api/README.md`). Collect the unique parent directories of your changed docs. Run each validator **once per unique parent**. Use `docs/` only when the docs you touched actually live there. The scripts accept any directory argument (default `.`).
6. **Run an independent read-only accuracy review after every docs write or edit, including a single-file change.**
   - **Preferred:** delegate to the **doc-reviewer** subagent through the Agent tool (`subagent_type: knowledge:doc-reviewer`). It independently checks that every referenced path, symbol, and link exists. It re-runs the validators.
   - **Safe fallback:** if the Agent tool is unavailable, perform the review inline yourself. Re-read each doc you touched. Verify that every referenced path, symbol, table, endpoint, and cross-link exists in the codebase. Re-run the three validation scripts.
   - Do not report the docs as done until this independent pass has run.
7. Report the validation and review results to the user. Lead with the state: `complete` (the independent review passed) or `blocked` (the preflight or the review stopped the work). For a blocked state, give the reason and the exact next action.

## User Request

Topic/context: **$ARGUMENTS**

## Validation Scripts

Run these after you write or update docs. Run them once per **unique parent directory** of the docs you touched. Replace `<dir>` with each such directory. Use the actual doc location (project root, `docs/`, or a module-adjacent directory), not a hard-coded `docs/`:

- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh <dir>`
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh <dir>`
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh <dir> 30`
