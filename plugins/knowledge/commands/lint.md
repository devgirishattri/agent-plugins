---
description: "Lint the memory store's frontmatter, schema, and index for defects (read-only)"
argument-hint: "[--store <path>]"
allowed-tools: Bash(bash:*)
---

## Instructions

`memory-lint.sh` is read-only: it never writes to the store, MEMORY.md, or any memory file. Run exactly one literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-lint.sh" [--store <path>]
```

Pass `--store <path>` only if the user supplied one in `$ARGUMENTS`; otherwise omit it and let the script resolve the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`).

Exit codes: `0` clean (no ERROR-level finding — ADVISORY/WARN findings may still be present and worth reporting); `2` usage error; `3` the store could not be resolved (report the stderr message verbatim — it will suggest `/knowledge:init` when no store exists yet, or name the ambiguous candidates when more than one is found); `4` at least one ERROR-level finding (a store-integrity issue such as a slug collision, or a schema ERROR).

## Output

Each finding is one tab-separated line: `<LEVEL>\t<file>\t<message>` with `LEVEL` in `ERROR` (must fix — schema violation, unparseable frontmatter, slug collision), `ADVISORY` (legacy-file migration guidance — a concrete proposed value where one is derivable, otherwise "needs a human value"), or `WARN`.

Group the findings by file when reporting to the user, lead with any `ERROR` rows, and summarize `ADVISORY` migration suggestions concisely rather than repeating every line verbatim. If the store is clean, say so plainly. Do not edit any file yourself based on these findings — this command is report-only; `/knowledge:consolidate` is the write path for issues it surfaces in the memory store.

$ARGUMENTS
