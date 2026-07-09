---
name: doc-review
description: This skill should be used to independently verify the accuracy of documentation after it has been written or updated — it checks that every referenced file path, function, table, endpoint, and cross-link actually exists in the codebase, and runs the plugin's validation scripts. Trigger it after creating or editing docs (e.g. "review the docs I just wrote", "verify docs/ARCHITECTURE.md is accurate", "check the documentation for stale references") or as the verification step of the creating-docs workflow. It reads and reports only; it does not edit files.
user-invocable: true
---

# Documentation Review

An independent verification pass over documentation. The goal is to confirm that a documentation file (or a docs directory) tells the truth about the codebase. This is a **read-and-report** task — never edit any file while performing this review.

## Inputs

The target is a single doc path (e.g. `docs/AUTH_FLOW.md`) or a directory (e.g. `docs/`). If none is given, default to `docs/`.

## Process

1. **Read the target docs.** Read every `.md` file in scope. Build a list of the
   concrete claims they make about the code: file paths, function/class/method
   names, table/collection names, API endpoints, env vars, CLI commands, and
   markdown cross-links to other docs.

2. **Verify each reference against the real codebase** using file search, grep,
   and reads:
   - **File paths** — confirm the file exists. Flag any that don't.
   - **Symbols** (functions, classes, tables, endpoints, env vars) — grep the
     codebase for a definition. Flag references with no match (possible rename or
     hallucination) and note the file:line where the real definition lives when
     found.
   - **Cross-links** — confirm linked `.md` files exist at the resolved path.
   - **Copied code / line numbers** — flag any embedded code block or `file:line`
     citation that no longer matches the source (these rot fast; reference-based
     notation is preferred).

3. **Run the plugin's validation scripts.** Resolve the plugin root with:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/creating-docs/1.1.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/creating-docs"
   ```

   Then run all three against the docs dir:

   ```bash
   bash "$PLUGIN_ROOT/scripts/validate-links.sh" <docs-dir>    # broken cross-references
   bash "$PLUGIN_ROOT/scripts/check-todos.sh" <docs-dir>       # stray TODO/FIXME markers
   bash "$PLUGIN_ROOT/scripts/check-freshness.sh" <docs-dir> 30  # docs older than referenced code
   ```

   Relay each script's findings. If the scripts aren't found, do the equivalent
   checks manually and say so.

4. **Check doc hygiene** briefly: every doc has a clear purpose/title, sections
   serve the reader, and reference-based notation is used instead of copied code
   where practical.

## Output

Return a concise, structured report:

- **Verdict:** ACCURATE / ISSUES FOUND
- **Broken references:** bullet list of `doc → reference (why)`, with the correct
  location if found. Empty list if none.
- **Stale / risky:** copied code, line-number citations, or freshness-flagged docs.
- **Validation script output:** pass/fail per script with the relevant lines.
- **Suggested fixes:** specific, file-scoped edits the user (or a follow-up task)
  should make. Do not apply them as part of this review.

Be precise and cite `file:line` for every claim. Do not speculate — if a
reference cannot be verified, say "unverified" rather than guessing. Never
modify files during this review.
