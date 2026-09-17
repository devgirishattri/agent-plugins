# Knowledge command details

Read when selecting command flags, context naming/evidence rules, or memory ranking.

## Which command, when

`$knowledge:find [--source all|docs|memory|context] [--store <path>] [--limit N] <query>` searches local docs, resolved memory, and configured context together, grouped by source with authority/lifetime labels. See the installed `find` skill for bounds and partial-result handling.

**Docs — see each installed command skill for the full process:**

| Command | Purpose |
|---|---|
| `$knowledge:docs-create [topic]` | Create or update project documentation using structured templates, reference-based notation, and validation tools. Runs the `docs-write.sh` reviewer-role preflight first (below). |
| `$knowledge:docs-review [target]` | Independently verify documentation accuracy against the codebase (report-only, no edits), delegating the installed review procedure to a fresh read-only subagent. |

**Context — each command has a same-named installed skill for its full
workflow:**

| Command | Purpose |
|---|---|
| `$knowledge:context-generate [name] [--handoff] [--expires <UTC-ISO>]` | Summarize the current session and save it. `--handoff` marks it a structured, promotable handoff instead of a point-in-time snapshot. |
| `$knowledge:context-list` | List snapshot names, line counts, timestamps, history counts, and (for handoffs) kind + expiry. |
| `$knowledge:context-verify <name> --repository-id <id> [--repo <path>] [--json]` | Read-only local path and commit checks for a v2 handoff. Recorded test/reference evidence remains unverified. |
| `$knowledge:context-load <name>` | Load a snapshot's contents into the current session; warns if stale. |
| `$knowledge:context-diff <name>` | Compare the current snapshot with archived versions. |
| `$knowledge:context-search <pattern> [--list]` | Read-only search of snapshot contents across local projects. |
| `$knowledge:context-share <session> [name]` | Notify another named pane that a shared snapshot is available (does not copy the file). |
| `$knowledge:context-remove <name>` | Preview, explicitly confirm, and delete one snapshot (and its history). |

Context snapshot and handoff names are canonical knowledge item names:
lowercase `snake_case` slugs matching `^[a-z0-9]+(_[a-z0-9]+)*$`. Pane
names are transport labels and may still use hyphens. The context store
hardening scanner enforces the same rule for existing snapshot files and
history stems; legacy hyphenated or uppercase context filenames fail closed
until explicitly migrated.

New handoffs authored by `context-generate --handoff` use v2 structured
repository scope, stable work-item IDs, reported statuses, and recorded
evidence. See [the handoff evidence contract](handoffs.md) for the
JSON staging format and compatibility rules. Existing v1 handoffs remain
supported. Evidence is fallible background, never automatically verified or
executed, and item status is not authoritative tracker state.

**Memory — the durable, agent-maintained store. `doctor`/`lint`/`search`/
`recall`/`graph` are read-only; `remember` is a low-friction inbox write;
`consolidate`/`promote` are the durable-store write paths; and `init`
bootstraps a new store:**

| Command | Purpose |
|---|---|
| `$knowledge:init [--store <path>]` | Bootstrap a new `.agents/memory/` store: a reviewable `.gitignore` PLAN, then an APPLY that verifies coverage before creating the store. Run this first if `doctor`/`lint`/etc. report no store found. |
| `$knowledge:doctor [--store <path>]` | Diagnose knowledge-store health (including v2 handoff timestamp consistency, evidence-age review cues, and explicitly linked memory lifecycle checks) across docs, memory, context, the `AGENTS.md` recall bridge, and provider capability — read-only, cross-store. Start here for an overall health check. |
| `$knowledge:lint [--store <path>] [--fix]` | Lint the memory store's frontmatter, schema, and index for defects — read-only by default. Narrower than `doctor`; use it when iterating on memory-file content directly. `--fix` is an opt-in normalizer that applies only the deterministic, low-risk repairs (canonicalize a mis-nested/absent top-level `status`; reconcile missing `MEMORY.md` index rows) — every write goes through `memory-write.sh` (reviewer-refused, CAS); anything needing human content (description, **Why:**/**How to apply:**, dates, ambiguous legacy `type`) is reported, never fabricated. |
| `$knowledge:search [--store <path>] [--limit N] [--json] [--explain] <query>` | Deterministic lexical ranked search over the memory store — read-only. Use to find a slug or check whether something is already recorded. |
| `$knowledge:recall [--store <path>] [--limit N] <query>` | The agent-facing wrapper over `search`: slug citations + bounded, query-anchored snippets framed as untrusted context. Use this (not `search`) when informing your own reasoning before a substantive task — see the recall bridge below. |
| `$knowledge:graph [--store <path>] [neighbors <slug> \| reverse <slug> \| orphans \| components \| --format json\|dot\|mermaid]` | Explicit-`[[slug]]`-link knowledge graph — read-only. Use to explore how memories connect, find orphaned files, or render a diagram. Automatic recall filters outgoing links separately; see `references/hooks.md`. |
| `$knowledge:remember [--store <path>] [--list [--expired-only]] [<what to remember>]` | Capture a low-friction candidate into the inbox for later `$knowledge:consolidate` review (or list/purge pending candidates). No ceremony — use this the moment a learning surfaces, mid-task. |
| `$knowledge:consolidate [--store <path>] [session learnings]` | Drain the inbox and this session's learnings into reviewed create/UPDATE diffs against `MEMORY.md`, applying only after approval. The memory module's core value — run this at session end, or whenever the inbox is non-empty. |
| `$knowledge:promote [context <name> \| memory <slug>] [--store <path>]` | Promote a stabilized context/handoff item or memory file into a memory create/UPDATE or a proposed docs patch, then — as a SEPARATE confirmation — delete the source. The lifecycle-closing surface for a handoff or a superseded memory file. |

## Search/recall ranking

`search`/`recall` rank by field weight — slug 8, name 6, tags 5, description
4, type 3, headings 2, backlink slugs 2, body 1, summed per matching field;
`stale`/`superseded`/`archived` entries are halved; ordering is score desc
then slug asc. These weights are published for writers, not just readers:
put an entry's load-bearing words in `tags`/`name` rather than only in prose
if you want it to surface reliably. `recall`'s third block line is a
query-anchored snippet of the body (windowed around wherever the query first
anchors, falling back to the first paragraph when no atom anchors in the
body at all), not always the first paragraph. A `search`/`recall` query of
2+ atoms that gets zero full-query hits automatically degrades to the
best-matching atom subset instead of returning an envelope indistinguishable
from "nothing is stored" — reported explicitly via a `degraded:` stderr/
envelope line or a JSON `degraded` object, never silently swapped in.
