---
description: Create or update project documentation using structured templates, reference-based notation, and validation tools
argument-hint: "[topic or file to document]"
allowed-tools: Read, Write, Edit, Glob, Grep, Bash(bash:*), Agent
disable-model-invocation: true
---

## Instructions

1. **Reviewer-role preflight — run FIRST, before any other step, and stop on non-zero.** First resolve the repository root in a SEPARATE read-only step by running `git rev-parse --show-toplevel` (if not a git repository, use the current working directory). Then invoke the preflight as exactly one literal Bash segment, substituting the resolved absolute path yourself — no `export`/`env`/assignment prefix, no command substitution, no chaining/piping/redirection:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/docs-write.sh" --repo "<REPO_ROOT>"
   ```
   - Exit `0`: proceed to step 2.
   - Any non-zero exit (e.g. `6` — `reviewer role: docs writes refused`, or an unresolved fleet identity): **stop immediately.** Do not read the skill, do not write or edit any file. Relay the script's stderr line to the user verbatim as the reason no docs were written.
2. Read the skill instructions at `${CLAUDE_PLUGIN_ROOT}/skills/docs-create/SKILL.md` using the Read tool
3. Follow the structured process to create or update documentation
4. If no topic is provided below, ask the user what they want to document
5. After writing docs, run the validation scripts using Bash against the **parent directory of each doc you actually created or edited** — a doc may live at the project root, under `docs/`, or module-adjacent (e.g. `src/api/README.md`). Collect the unique parent directories of your changed docs and run each validator **once per unique parent**; use `docs/` only when that is where the docs you touched actually live. The scripts accept any directory argument (default `.`).
6. **Always run an independent read-only accuracy review after ANY docs write/edit — never skip it, even for a single-file change.** Prefer delegating to the **doc-reviewer** subagent via the Agent tool (`subagent_type: knowledge:doc-reviewer`); it independently checks that every referenced path/symbol/link exists and re-runs the validators. **Safe fallback:** if the Agent tool is unavailable, perform the review inline yourself — re-read each doc you touched, verify every referenced path/symbol/table/endpoint/cross-link actually exists in the codebase, and re-run the three validation scripts. Do not report the docs as done until this independent pass has run.
7. Report validation + review results to the user

## User Request

Topic/context: **$ARGUMENTS**

## Validation Scripts

Run these after writing or updating docs, once per **unique parent directory** of
the docs you touched. Replace `<dir>` with each such directory (the actual doc
location — project root, `docs/`, or a module-adjacent dir — not a hard-coded
`docs/`):

- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-todos.sh <dir>`
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/validate-links.sh <dir>`
- `bash ${CLAUDE_PLUGIN_ROOT}/scripts/check-freshness.sh <dir> 30`
