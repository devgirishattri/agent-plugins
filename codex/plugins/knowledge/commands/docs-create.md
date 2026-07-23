---
description: Create or update project documentation using structured templates and validation tools
argument-hint: "[topic or file to document]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Never derive it from the project working directory or embed a cache version.

2. Resolve the repository root in a separate read-only step with
   `git rev-parse --show-toplevel`. If this is not a Git repository, resolve
   the current working directory instead. Substitute that absolute path
   literally for `<REPO_ROOT>` below; do not run discovery inside the helper
   invocation.

3. **Reviewer-role preflight — MANDATORY, run FIRST, before any other step, and stop on non-zero.** Invoke as one literal Bash segment (no `export`/`env`/assignment prefix, command substitution, chaining, piping, or redirection):

   ```bash
   bash "<PLUGIN_ROOT>/scripts/docs-write.sh" --repo "<REPO_ROOT>"
   ```

   Exit `0` means proceed to step 4. Any non-zero exit — including `6` with stderr `reviewer role: docs writes refused`, or an unresolved fleet identity asking to set `KNOWLEDGE_PANE_NAME` — means **stop immediately**: do not read the skill, do not write or edit any file. Relay the script's stderr line to the user as the reason no docs were written.

4. Read the skill instructions at `$PLUGIN_ROOT/skills/docs-create/SKILL.md`.
5. Follow the structured process to create or update documentation.
6. If no topic is provided in `$ARGUMENTS`, ask the user what they want to document.
7. After writing or updating docs, derive the unique parent directory of every
   changed documentation file. Run the validators once per parent directory;
   use `docs/` only when that is actually the changed document's parent:

   ```bash
   DOCS_DIR="<parent directory of changed doc>"
   bash "$PLUGIN_ROOT/scripts/check-todos.sh" "$DOCS_DIR"
   bash "$PLUGIN_ROOT/scripts/validate-links.sh" "$DOCS_DIR"
   bash "$PLUGIN_ROOT/scripts/check-freshness.sh" "$DOCS_DIR" 30
   ```

8. Delegate an independent, report-only review of the changed docs to a fresh subagent using `$PLUGIN_ROOT/skills/docs-review/SKILL.md`. Give it the target and absolute `PLUGIN_ROOT`, explicitly tell it not to delegate again or edit files, wait for it, and relay the verdict. Only when the runtime has no delegation capability may you review directly; disclose that non-independent fallback.
9. Report the validation and independent-review results to the user.

## User Request

Topic/context: `$ARGUMENTS`
