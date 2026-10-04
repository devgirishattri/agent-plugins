---
name: doctor
description: Diagnose knowledge-store health across docs, memory, context, AGENTS.md recall bridge, and provider capability — read-only, cross-store.
when_to_use: User asks whether the knowledge store is healthy, misconfigured, or why recall/capture is not working ("knowledge doctor", "check the memory store", "why is recall empty").
argument-hint: "[--store <path>]"
allowed-tools: Bash(bash:*)
---

## Instructions

`doctor.sh` is STRICTLY read-only. It never writes to docs, the memory store, MEMORY.md, any memory file, the capture inbox, the context store, or `AGENTS.md`. Every check reads, stats, or invokes another read-only helper. It never invokes `memory-write.sh`, not even its `unlock` subcommand, because `unlock` removes a dead lock.

Run exactly **one** literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" [--store <path>]
```

Pass `--store <path>` only if the user supplied one in `$ARGUMENTS`. That is the whole argv grammar. Anything else is a usage error.

What `--store <path>` governs (same precedence as every other memory command: explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`):

- It governs ONLY the memory-module section and the lock-diagnostics section.
- It also governs the explicit memory-link checks inside the context-handoff findings. There it only changes which store a `memory:<slug>` reference resolves against.

What `--store <path>` does not govern:

- The docs and AGENTS.md sections always target the repository root. They never take `--store`.
- The capability-matrix section reads only repository-rooted and HOME-rooted provider files. Several of its findings compare against the already-resolved store.
- The context section reads the handoff files from `SESSION_CONTEXT_HOME` regardless of `--store`. When that variable is unset, it reads the repository's own `.tmp/contexts`.

Exit codes:

| Code | Meaning | Required action |
|---|---|---|
| `0` | Clean: no `WARN` or `ERROR` finding. `INFO` findings can still be present. | Report the store as clean. Relay worthwhile `INFO` findings, such as the review queue or capability-matrix rows. |
| `1` | At least one `WARN` or `ERROR` finding is present. Doctor is a reporter, not a mutating helper. This code means "there is something to look at", not "the command failed". | Report the findings by section. |
| `2` | Usage error. | Relay the usage message. |
| `3` | Hard failure: the current directory is not inside a git repository, so no section had anywhere to look. | Tell the user to run it from inside a repository. |

## Output

Each finding is one tab-separated line: `<LEVEL>\t<section>\t<message>`.

| `LEVEL` | Meaning |
|---|---|
| `INFO` | Informational: review-queue entries, capability-matrix rows, confirmations. |
| `WARN` | An actionable defect: stale snapshot, dangling/convention-drift link, index drift, misconfiguration, orphaned lock/claim/journal/staged file, stale doc, provider capability mismatch. |
| `ERROR` | A store-integrity violation: slug collision, unsafe permissions, a store that isn't gitignored, unparseable frontmatter. |

`section` is a short identifier, for example `docs-taxonomy`, `docs-todos`, `docs-links`, `docs-freshness`, `memory-resolve`, `memory-lint`, `memory-index`, `memory-backlinks`, `memory-inbox`, `memory-review-queue`, `memory-hardening`, `memory-lock`, `context`, `context-handoff`, `agents-md`, `capability-matrix`, `capability-claude`, `capability-codex`, `capability-recall`.

The `memory-backlinks` check ignores links inside fenced code blocks and single-backtick inline code spans.

Report the findings in this order:

1. Group the findings by section.
2. Lead with any `ERROR` rows, then `WARN` rows.
3. Summarize `INFO` rows briefly. Do not repeat every line verbatim.

When `agents-md` reports a missing, duplicated, or divergent recall snippet, it also prints the exact bytes to paste. These are a run of `INFO\tagents-md\tsnippet> <line>` rows. Relay those rows verbatim as a fenced block. The user pastes them into `AGENTS.md` themselves. This command never edits `AGENTS.md`, or anything else.

If the store is clean, say so plainly. Still mention any `INFO`-level review-queue or capability-matrix items that deserve the user's attention.

### Context-handoff findings

Version 1 handoffs remain supported. For version 2, doctor validates scope and items structurally with `handoff-data.py`. Malformed data produces a WARN. Valid work items are reported with evidence counts labelled `recorded, not verified`. The freshness and consistency assessment follows (`validate --assess`, one call per handoff, with the current UTC time and `SESSION_CONTEXT_STALE_DAYS`). A `SESSION_CONTEXT_STALE_DAYS` value outside 0-999999 produces one `WARN context` finding. Then both the file-age check and the evidence-age check fall back to 7 days.

`WARN` is for internal inconsistencies:

- Evidence `observed_at` is more than 300 seconds in the future.
- Evidence is observed more than 300 seconds after the handoff's `updated`.
- `created` is later than `updated`.
- `updated` is more than 300 seconds in the future.
- An expired handoff still has `pending`, `in_progress`, or `blocked` items.

`INFO` is for age and queue facts:

- An `in_progress` or `blocked` item whose newest evidence is N days old or more at the stale threshold. The age is measured on `observed_at`, not file mtime. It is reported separately from the mtime tier.
- A `done` item whose evidence is only `test` or `reference`. This is unverifiable by design, not a defect.
- A handoff whose items are all `done` or `cancelled`. It is a candidate for `/knowledge:promote`.

These checks are pure functions of the file and the clock. Doctor does not match any item to a memory entry or tracker line by name. It does not treat any completion claim as true.

The one filesystem check is explicit. A `reference` evidence written as `memory:<slug>` names a memory entry. Doctor reads that entry's top-level `status` from the memory store it resolved for this run. Therefore `--store` redirects the memory-link checks. The context store is still `SESSION_CONTEXT_HOME`.

- `INFO`: the entry is active, the entry has no explicit status, or no store was resolved at all (one line per handoff, never a fallback store).
- `WARN`: the entry is missing, stale, superseded, or archived. Also `WARN` when its frontmatter cannot be assessed (symlink, unreadable, duplicate or unrecognised status), when the link is malformed, or when a resolved store fails its own safety validation.

Doctor does not check file existence, commit membership, test results, or evidence truth. It never executes or fetches evidence references. The narrow local checks (path existence and type, commit presence and `HEAD` ancestry) belong to `/knowledge:context-verify`. That skill runs them per handoff against an explicitly bound repository.

Do not fix anything based on these findings yourself. This command is report-only. Point the user to the right path:

- Memory-store issues: `/knowledge:lint`, `/knowledge:consolidate`, and `/knowledge:promote` are the write paths.
- Docs findings: the user fixes them by editing the doc directly.
- Lock, journal, and staged-file findings: the finding names the exact recovery command to run.

$ARGUMENTS
