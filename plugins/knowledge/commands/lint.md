---
description: "Lint the memory store's frontmatter, schema, and index for defects (read-only)"
argument-hint: "[--store <path>]"
allowed-tools: Bash(bash:*)
---

## Instructions

`memory-lint.sh` is read-only. It never writes to the store, `MEMORY.md`, or any memory file. Run exactly one literal Bash segment. Use no `export`, `env`, or assignment prefix. Do not chain, pipe, or redirect:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-lint.sh" [--store <path>]
```

Pass `--store <path>` only if the user supplied one in `$ARGUMENTS`. Otherwise omit it. The script then resolves the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`).

## Exit codes

| Exit | Meaning | Next action |
|---|---|---|
| `0` | Clean: no ERROR-level finding. ADVISORY and WARN findings can still be present. | Report them. |
| `2` | Usage error. | Report the stderr usage line. |
| `3` | The store could not be resolved. | Report the stderr message verbatim. It suggests `/knowledge:init` when no store exists. It names the ambiguous candidates when more than one is found. |
| `4` | At least one ERROR-level finding: a store-integrity issue such as a slug collision, or a schema ERROR. | Report the findings. |

## Output

Each finding is one tab-separated line: `<LEVEL>\t<file>\t<message>`. `LEVEL` is one of three values:
- `ERROR`: must fix. Examples are a schema violation, unparseable frontmatter, and a slug collision.
- `ADVISORY`: legacy-file migration guidance. The line gives a concrete proposed value where one is derivable. Otherwise it says "needs a human value".
- `WARN`.

Report to the user:
1. Lead with the result: clean, or the count of findings per level.
2. Group the findings by file. List any `ERROR` rows first.
3. Summarize `ADVISORY` migration suggestions concisely. Do not repeat every line verbatim.
4. If the store is clean, say so plainly.

Do not edit any file based on these findings. This command is report-only. `/knowledge:consolidate` is the write path for issues that it surfaces in the memory store.

$ARGUMENTS
