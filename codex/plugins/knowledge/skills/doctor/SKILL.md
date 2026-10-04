---
name: doctor
description: "Diagnose knowledge-store health across docs, memory, context, AGENTS.md, and provider capability (strictly read-only, cross-store)."
---

# Doctor

When this skill is invoked, run the helper directly and return its grouped findings or the shortest actionable failure.

Resolve `PLUGIN_ROOT` from this selected skill's installed absolute source path: it is the directory two levels above this `SKILL.md`. Substitute that absolute path literally in the helper invocation below; never infer it from the project working directory or hardcode a marketplace cache version.

`doctor.sh` is STRICTLY read-only. It never writes to docs, the memory store, MEMORY.md, any memory file, the capture inbox, the context store, or `AGENTS.md`. Every check reads, stats, or invokes another read-only helper. It never invokes `memory-write.sh`, not even its `unlock` subcommand, because `unlock` removes a dead lock.

Run exactly **one** literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):

```
bash "<PLUGIN_ROOT>/scripts/doctor.sh" [--store <path>]
```

Pass `--store <path>` only if the user supplied it in the user's arguments.
It selects the resolved memory store for memory/lock checks and explicit
`memory:<slug>` handoff links. Precedence is explicit target, then
`KNOWLEDGE_MEMORY_HOME`, then canonical discovery under `.agents/memory/`.
Handoff files still come from `SESSION_CONTEXT_HOME` or doctor's repository-local
`.tmp/contexts` default. Docs and AGENTS.md checks target the repository;
capability checks inspect repository/home configuration and also consult the
resolved memory store. That is the whole argv grammar; other arguments are
usage errors.

| Code | Meaning | Required action |
|---|---|---|
| `0` | Clean: no `WARN` or `ERROR` finding. `INFO` findings can still be present. | Report the store as clean. Relay worthwhile `INFO` findings, such as the review queue or capability-matrix rows. |
| `1` | At least one `WARN` or `ERROR` finding is present. Doctor is a reporter, not a mutating helper. This code means "there is something to look at", not "the command failed". | Report the findings by section. |
| `2` | Usage error. | Relay the usage message. |
| `3` | Hard failure: the current directory is not inside a git repository, so no section had anywhere to look. | Tell the user to run it from inside a repository. |

## Output

For `context-handoff`, v1 remains supported. V2 scope/items are structurally
validated and assessed with `handoff-data.py validate --assess`. Per-item
summaries still label evidence `recorded, not verified`.

WARN findings flag future evidence or evidence after `updated` (more than
300 seconds), `created` after `updated`, `updated` more than 300 seconds in
the future, and expired handoffs with open items. INFO findings flag old
newest evidence on `in_progress`/`blocked` items, `done` claims backed only by
`test`/`reference` evidence, and handoffs reporting all items done/cancelled.
Evidence age uses `observed_at`, independently of file modification time.
`SESSION_CONTEXT_STALE_DAYS` supplies the threshold for both age checks
(default 7; nonnegative integer 0-999999). Invalid values produce a WARN and
fall back to 7 in doctor. At the threshold, an evidence-age INFO is emitted.

An evidence entry with `kind: reference` and `ref: memory:<canonical_slug>`
explicitly names `<resolved-memory-store>/<canonical_slug>.md`. Doctor warns
about missing entries, stale/superseded/archived status, malformed links, or
unsafe/unreadable entries. Active status is informational; absent explicit
status is reported as unverified. Only a recognized top-level lifecycle scalar
is assessed; duplicate or unrecognized status values produce a warning.
If no memory store resolves, doctor reports one INFO per linked handoff
and never falls back to another store. A resolved store that fails the safety
recheck produces a WARN instead. `context-verify` continues to leave
these reference entries unverified.

These are review cues, not proof of completion or staleness. Only explicitly
linked entries are inspected; no cross-store item identity or status equality
is inferred. Doctor never executes or fetches
recorded evidence. For local path and commit checks, use
`$knowledge:context-verify <name> --repository-id <id>` against an explicitly
bound repository.

Each finding is one tab-separated line: `<LEVEL>\t<section>\t<message>`.

| `LEVEL` | Meaning |
|---|---|
| `INFO` | Informational: review-queue entries, capability-matrix rows, confirmations. |
| `WARN` | An actionable defect: stale snapshot, dangling/convention-drift link, index drift, misconfiguration, orphaned lock/claim/journal/staged file, stale doc, provider capability mismatch. |
| `ERROR` | A store-integrity violation: slug collision, unsafe permissions, a store that isn't gitignored, unparseable frontmatter. |

`section` is a short identifier, for example `docs-taxonomy`, `docs-todos`, `docs-links`, `docs-freshness`, `memory-resolve`, `memory-lint`, `memory-index`, `memory-backlinks`, `memory-inbox`, `memory-review-queue`, `memory-hardening`, `memory-lock`, `context`, `context-handoff`, `agents-md`, `capability-matrix`, `capability-claude`, `capability-codex`, `capability-recall`.

The `memory-backlinks` check ignores links inside fenced code blocks and single-backtick inline code spans.

Group findings by section. Lead with `ERROR` rows, then `WARN` rows.
Summarize `INFO` rows briefly.

For a missing, duplicated, or divergent recall snippet, `agents-md` prints
`INFO\tagents-md\tsnippet> <line>` rows. Relay those exact bytes in a fenced block.
The user can paste them into `AGENTS.md`. This skill never edits any file.
If the store is clean, say so. Still mention useful review-queue or capability-matrix information.

Do not attempt to fix anything based on these findings yourself — this skill is report-only. `$knowledge:lint`, `$knowledge:consolidate`, and `$knowledge:promote` are the write paths for the issues it surfaces in the memory store; docs findings are fixed by editing the doc directly; lock/journal/staged findings name the exact recovery command to run.
