---
description: "Lint the memory store's frontmatter, schema, and index for defects (read-only)"
argument-hint: "[--store <path>]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from this command resource's absolute source path: its
   parent is `<plugin-root>/commands`, so go up one directory. Never derive it
   from the project working directory or embed a marketplace cache version.

2. Run exactly one literal Bash segment (no `export`/`env`/assignment prefix,
   no command substitution, chaining, piping, or redirection):

   ```bash
   bash "<PLUGIN_ROOT>/scripts/memory-lint.sh" [--store "<path>"]
   ```

   Pass `--store "<path>"` only when the user supplied one; otherwise omit it
   and let the helper resolve the store through explicit target,
   `KNOWLEDGE_MEMORY_HOME`, then canonical `.agents/memory/` discovery.

3. Interpret exits as follows: `0` means no ERROR-level finding (ADVISORY/WARN
   rows may still be present); `2` usage error; `3` store-resolution failure;
   `4` store-integrity or schema ERROR. Relay stderr verbatim for non-zero
   resolution/integrity failures.

4. Each stdout finding is tab-separated as
   `<LEVEL>\t<file>\t<message>`, where LEVEL is `ERROR`, `ADVISORY`, or `WARN`.
   Group findings by file, lead with ERROR rows, summarize migration advice,
   and report a clean store plainly. This command is read-only: never edit a
   file based on its findings.

## User Request

Arguments: `$ARGUMENTS`
