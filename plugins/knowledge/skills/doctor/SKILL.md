---
name: doctor
description: Diagnose knowledge-store health across docs, memory, context, AGENTS.md recall bridge, and provider capability — read-only, cross-store.
when_to_use: User asks whether the knowledge store is healthy, misconfigured, or why recall/capture is not working ("knowledge doctor", "check the memory store", "why is recall empty").
argument-hint: "[--store <path>]"
allowed-tools: Bash(bash:*)
---

## Instructions

`doctor.sh` is STRICTLY read-only: it never writes to docs, the memory store, MEMORY.md, any memory file, the capture inbox, the context store, or `AGENTS.md` — every check reads, stats, or invokes another read-only helper (never `memory-write.sh`, not even its `unlock` subcommand, which itself removes a dead lock). Run exactly **one** literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/doctor.sh" [--store <path>]
```

Pass `--store <path>` only if the user supplied one in `$ARGUMENTS`; it governs ONLY the memory-module and lock-diagnostics sections plus the explicit memory-link checks inside the context-handoff findings (where it only changes which store a `memory:<slug>` reference resolves against) (same precedence as every other memory command: explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`). The docs and AGENTS.md sections always target the repository root and never take `--store`; the capability-matrix section reads only repository- and HOME-rooted provider files, though several of its findings compare against the already-resolved store; the context section reads the handoff files from `SESSION_CONTEXT_HOME` (or, when that variable is unset, the repository's own `.tmp/contexts`) regardless of `--store`. That is the whole argv grammar — anything else is a usage error.

Exit codes: `0` clean (no `WARN`/`ERROR` finding — `INFO` findings may still be present and worth relaying, e.g. the review queue or capability-matrix rows); `1` at least one `WARN` or `ERROR` finding is present (doctor is a reporter, not a mutating helper — a non-zero exit here means "there is something to look at," not "the command failed"); `2` usage error; `3` hard failure — the current directory is not inside a git repository, so no section had anywhere to look.

## Output

Each finding is one tab-separated line: `<LEVEL>\t<section>\t<message>` with `LEVEL` in `INFO` (informational — review-queue entries, capability-matrix rows, confirmations), `WARN` (an actionable defect: stale snapshot, dangling/convention-drift link, index drift, misconfiguration, orphaned lock/claim/journal/staged file, stale doc, provider capability mismatch), or `ERROR` (a store-integrity violation: slug collision, unsafe permissions, a store that isn't gitignored, unparseable frontmatter). `section` is a short identifier, e.g. `docs-taxonomy`, `docs-todos`, `docs-links`, `docs-freshness`, `memory-resolve`, `memory-lint`, `memory-index`, `memory-backlinks`, `memory-inbox`, `memory-review-queue`, `memory-hardening`, `memory-lock`, `context`, `context-handoff`, `agents-md`, `capability-matrix`, `capability-claude`, `capability-codex`, `capability-recall`.

Group the findings by section when reporting to the user, lead with any `ERROR` rows, then `WARN`, then summarize `INFO` rows briefly rather than repeating every line verbatim. When `agents-md` reports a missing, duplicated, or divergent recall snippet, it also prints the exact bytes to paste as a run of `INFO\tagents-md\tsnippet> <line>` rows — relay those verbatim as a fenced block for the user to paste into `AGENTS.md` themselves; this command never edits `AGENTS.md`, or anything else. If the store is clean, say so plainly, and still mention any `INFO`-level review-queue or capability-matrix items worth the user's attention.

For `context-handoff`, v1 remains supported. V2 scope/items are structurally
validated with `handoff-data.py`; malformed data produces a WARN. Valid work
items are reported with evidence counts labelled `recorded, not verified`,
followed by the freshness and consistency assessment (`validate --assess`, one
call per handoff with the current UTC time and `SESSION_CONTEXT_STALE_DAYS`;
a value outside 0–999999 produces one `WARN context` finding and both the
file-age and evidence-age checks fall back to 7 days):
`WARN` for internal inconsistencies — evidence `observed_at` more than 300
seconds in the future, evidence observed more than 300 seconds after the
handoff's `updated`, `created` later than `updated`, `updated` more than 300
seconds in the future, or an
expired handoff that still has `pending`/`in_progress`/`blocked` items; `INFO`
for age and queue facts — an `in_progress`/`blocked` item whose newest
evidence is N days old or more at the stale threshold (measured on `observed_at`, not
file mtime, and reported separately from the mtime tier), a `done` item whose
evidence is only `test`/`reference` (unverifiable by design, not a defect),
and a handoff whose items are all `done`/`cancelled` (a candidate for
`/knowledge:promote`). These are pure functions of the file and the clock: no
item is matched to a memory entry or tracker line by name, and no completion
claim is treated as true. The one filesystem check is explicit: a `reference`
evidence written as `memory:<slug>` names a memory entry, and doctor reads that
entry's top-level `status` from the memory store it resolved for this run
(`--store` therefore redirects the memory-link checks; the context store is
still `SESSION_CONTEXT_HOME`) — `INFO` when active, when the entry has no explicit status, or when no
store was resolved at all (one line per handoff, never a fallback store);
`WARN` when the entry is missing, stale, superseded, or archived, when its
frontmatter cannot be assessed (symlink, unreadable, duplicate or
unrecognised status), when the link is malformed, or when a resolved store
fails its own safety validation. This does not check file existence, commit
membership, test results, or evidence truth, and it never executes or fetches
evidence references. The narrow
local checks (path existence and type, commit presence and `HEAD` ancestry)
are `/knowledge:context-verify`'s job, run per handoff against an explicitly
bound repository.

Do not attempt to fix anything based on these findings yourself — this command is report-only. `/knowledge:lint`, `/knowledge:consolidate`, and `/knowledge:promote` are the write paths for the issues it surfaces in the memory store; docs findings are fixed by editing the doc directly; lock/journal/staged findings name the exact recovery command to run.

$ARGUMENTS
