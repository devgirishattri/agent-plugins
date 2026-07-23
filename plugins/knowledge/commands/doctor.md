---
description: "Diagnose knowledge-store health across docs, memory, context, AGENTS.md, and provider capability (read-only, cross-store)"
argument-hint: "[--store <path>]"
allowed-tools: Bash(bash:*)
---

## Instructions

`doctor.sh` is STRICTLY read-only: it never writes to docs, the memory store, MEMORY.md, any memory file, the capture inbox, the context store, or `AGENTS.md` — every check reads, stats, or invokes another read-only helper (never `memory-write.sh`, not even its `unlock` subcommand, which itself removes a dead lock). Run exactly **one** literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" [--store <path>]
```

Pass `--store <path>` only if the user supplied one in `$ARGUMENTS`; it governs ONLY the memory-module and lock-diagnostics sections (same precedence as every other memory command: explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`). The docs, context, AGENTS.md, capability-matrix, and duplicate-plugin sections always target the repository root and never take `--store`. That is the whole argv grammar — anything else is a usage error.

Exit codes: `0` clean (no `WARN`/`ERROR` finding — `INFO` findings may still be present and worth relaying, e.g. the review queue or capability-matrix rows); `1` at least one `WARN` or `ERROR` finding is present (doctor is a reporter, not a mutating helper — a non-zero exit here means "there is something to look at," not "the command failed"); `2` usage error; `3` hard failure — the current directory is not inside a git repository, so no section had anywhere to look.

## Output

Each finding is one tab-separated line: `<LEVEL>\t<section>\t<message>` with `LEVEL` in `INFO` (informational — review-queue entries, capability-matrix rows, confirmations), `WARN` (an actionable defect: stale snapshot, dangling/convention-drift link, index drift, misconfiguration, orphaned lock/claim/journal/staged file, stale doc, rejected-scope setting), or `ERROR` (a store-integrity violation: slug collision, unsafe permissions, a store that isn't gitignored, unparseable frontmatter). `section` is a short identifier, e.g. `docs-taxonomy`, `docs-todos`, `docs-links`, `docs-freshness`, `memory-resolve`, `memory-lint`, `memory-index`, `memory-backlinks`, `memory-inbox`, `memory-review-queue`, `memory-hardening`, `memory-lock`, `context`, `agents-md`, `capability-matrix`, `capability-claude`, `capability-codex`, `capability-recall`, `duplicate-plugin`.

Group the findings by section when reporting to the user, lead with any `ERROR` rows, then `WARN`, then summarize `INFO` rows briefly rather than repeating every line verbatim. When `agents-md` reports a missing, duplicated, or divergent recall snippet, it also prints the exact bytes to paste as a run of `INFO\tagents-md\tsnippet> <line>` rows — relay those verbatim as a fenced block for the user to paste into `AGENTS.md` themselves; this command never edits `AGENTS.md`, or anything else. If the store is clean, say so plainly, and still mention any `INFO`-level review-queue or capability-matrix items worth the user's attention.

Do not attempt to fix anything based on these findings yourself — this command is report-only. `/knowledge:lint`, `/knowledge:consolidate`, and `/knowledge:promote` are the write paths for the issues it surfaces in the memory store; docs findings are fixed by editing the doc directly; lock/journal/staged findings name the exact recovery command to run.

$ARGUMENTS
