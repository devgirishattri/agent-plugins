---
name: consolidate
description: Review captured learnings and memory inbox items, propose durable create/update diffs, and apply approved changes. User-run only; nothing is written without explicit approval.
---

# Consolidate

`consolidate` turns inbox captures and session learnings into reviewed markdown diffs.
Apply them only through `memory-write.sh apply`, after the user approves every diff.
Propose an **UPDATE** whenever an existing file plausibly covers the learning.
This judgment is yours; no script makes it for you.
The writer handles locking, CAS, reviewer refusal, and candidate consumption.
This skill stages scratch content and drives the writer. Never write store files directly.

Resolve `PLUGIN_ROOT` from this selected skill's installed absolute source path: it is the directory two levels above this `SKILL.md`. Substitute that absolute path literally in every helper invocation below; never infer it from the project working directory or hardcode a marketplace cache version.

Read this whole document before starting. Do not skip steps or reorder them.
Before applying anything, show the complete diff set and obtain user approval (step 7).
Never propose fixes outside `.agents/memory/`.
Docs, TODO/ISSUES trackers, and context snapshots have separate workflows (see "Non-goals").

`distill` can compose this workflow for a user-directed session wrap-up.
The user approves the same complete target/index diffs and candidate dispositions
within Distill's batch. That approval is sufficient.
No second invocation or duplicate approval is needed.
All baseline, role, CAS and exit gates still apply.
When selecting candidates for Distill, match writer-assigned `origin_session`
against the inherited runtime session ID. Missing/unknown or foreign origins
stay pending by default. Ordinary explicit consolidation retains its full-inbox
scope. Show evidence and origin when reviewing candidates; attribution is not
authorization and does not establish truth.

**Compatibility:** pre-0.5.0 readers reject candidate `origin_session`,
`origin_pane`, and `evidence` fields. Before downgrading, consolidate, dismiss,
or back up pending candidates. New-format candidates do not support transparent rollback.

## 0. Invocation discipline (read this first)

Every call into a plugin helper script below is **exactly one literal Bash
segment**: the literal word `bash`, then the plugin-relative script path
(`"<PLUGIN_ROOT>/scripts/<name>.sh"`), then flags. Add nothing else. No
`export`/`env`/inline-assignment prefix. No `&&`, `;`, `|`, `>`, `<`, backticks,
or `$(...)` inside that segment. Never combine two scripts on one line.
Never wrap a call as `bash -c "..."`. It is not a recognized helper invocation.

Compute each prerequisite in a separate step: resolved path, sha256 hash,
repository root, or current file content. Use read-only commands such as
`git rev-parse --show-toplevel`, `shasum -a 256 <file>`, or native file tools.
Substitute the returned literal value in the next helper call.
Never combine computation with the helper invocation.

Never construct a staged file with a Bash heredoc. Use the **file-editing tool** to
create every staged-target / staged-index file at a scratch location outside
the store. For example, create a directory once with a separate `mktemp -d`
call, under the OS temp directory. This keeps every helper invocation a single
literal segment. It also keeps the store itself untouched by anything but the
writer.

## 1. Resolve the store

If the user (or the user's arguments) gave an explicit `--store <path>`, that is your
`STORE_PATH` — skip to step 2.

Otherwise, derive a candidate path yourself, mirroring (not replacing) the
spec's canonical discovery algorithm, using only plain read-only commands, each
its own step:

1. `git rev-parse --show-toplevel` → `REPO_ROOT` (if this fails, you are not
   inside a git repository; stop and tell the user so — there is nothing to
   resolve).
2. Check `KNOWLEDGE_MEMORY_HOME` in the current environment (a plain
   `echo "${KNOWLEDGE_MEMORY_HOME:-}"`). If set and non-empty, that is your
   candidate `STORE_PATH`.
3. Otherwise check whether `<REPO_ROOT>/.agents/memory/MEMORY.md` exists (a
   plain `test -f` / file-search check). If it does, `STORE_PATH` =
   `<REPO_ROOT>/.agents/memory`.
4. Otherwise enumerate the immediate subdirectories of
   `<REPO_ROOT>/.agents/memory` (a plain `find <dir> -mindepth 1 -maxdepth 1
   -type d`) and check each for a `MEMORY.md`. If **exactly one** has one, that
   subdirectory is your candidate `STORE_PATH`. If zero or more than one do,
   you do not have a candidate — proceed to step 2 below anyway (omit
   `--store`) and let the real resolver's error message be authoritative.

This is a convenience derivation only, never the authority. The very next step
(baseline health) runs the real, single implementation of this algorithm
(`lib.sh`'s `km_resolve_store`, shared by every helper script) and its exit
code is what actually decides whether you have a usable store. If your
candidate and the real resolver ever disagree, the real resolver wins — stop
and ask, never guess further.

## 2. Baseline health gate

Run all three, each as its own single literal Bash segment, passing
`--store "<STORE_PATH>"` if you derived one in step 1 (omit it if you did not):

```
bash "<PLUGIN_ROOT>/scripts/memory-lint.sh" [--store <path>]
bash "<PLUGIN_ROOT>/scripts/memory-index.sh" [--store <path>]
bash "<PLUGIN_ROOT>/scripts/memory-backlinks.sh" [--store <path>] report
```

Gate results:

| Command and exit code | Meaning | Required action |
|---|---|---|
| Any of the three exits `3` | Store resolution failed (not found, or ambiguous; the message lists every candidate). | **Stop.** Relay the message verbatim. Ask the user for an explicit `--store <path>`, or point at `$knowledge:init` if no store exists at all. Do not guess. |
| `memory-lint.sh` exits `4` | At least one `ERROR`-level finding: a schema violation, unparseable frontmatter, or a slug collision. | **Stop the whole run.** Report every `ERROR` row. Do not propose any diffs against a store that already fails its own integrity checks. The user (or `$knowledge:lint` directly) must fix these first. |
| `memory-lint.sh` reports `ADVISORY` or `WARN` rows | Informational. | Carry them forward for the final report. |
| `memory-index.sh` exits `4` | Slug collision, or an ambiguous mixed index style that `memory-index.sh` cannot reconcile safely. | **Stop**, same as for `memory-lint.sh`. |
| `memory-index.sh` exits `0` with `DRIFT` lines | Informational. | Note the lines. |
| `memory-backlinks.sh report` exits `4` | Slug collision, or a filename stem outside the safe grammar. | **Stop**, same as above. |
| `memory-backlinks.sh report` exits `0` | It always exits `0` when it runs at all. Its stderr lines (`convention drift: [[x]] -> y` / `dangling: [[x]]`) are informational. | Keep the list of existing danglers. Then your own new diffs are not blamed for pre-existing ones later. |

If nothing stopped the run, the store is healthy enough to propose against.
Verify that you now have `STORE_PATH`.

## 3. Read MEMORY.md — index first

Before you look at anything else, **Read** `<STORE_PATH>/MEMORY.md` in full.
This human-curated overview of what already exists is your first and best dedup
signal. A name or topic that you recognize here, before you run a search, should
become an UPDATE, not a new file.

While you read, note the **detected index style**. You must preserve it when you
add rows later:

- **flat** — a plain list of membership rows: bullet, display name linked to
  the memory file basename, then hook text; no headings.
- **sectioned** — the same rows grouped under `#`/`##` headings (commonly by
  `metadata.type` or topic).
- **multi-link** — some rows carry more than one `](...)` link on the same
  line (the first is membership; any further links are cross-references) —
  this can coexist with either flat or sectioned.
- **degenerate** — free prose with no index rows at all, or index rows mixed
  with inline knowledge prose. `memory-lint.sh`/`memory-index.sh` already
  flagged this as ADVISORY in step 2; if so, propose a minimal index skeleton
  (or an extraction of the inline prose into its own file) as part of the same
  diff batch in step 6, using flat style unless the surrounding content
  clearly implies sections.

## 4. Gather inputs

Two sources, both in scope for this run:

1. **Session learnings** — anything the user's arguments supplied, plus anything from
   this conversation that reads as a durable learning, decision, or
   how-to-work feedback worth persisting. Use judgment: don't invent a
   learning that didn't happen, and don't propose a diff for ephemeral
   chatter that isn't durable knowledge. A learning that traces back to a
   closed TODO/ISSUES/ticket item is treated exactly like any other learning
   — see "Non-goals" below for the hard rule about never touching the
   tracker file itself.
2. **Inbox candidates** — run:
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" --store <STORE_PATH> --list
   ```
   (always pass the resolved `--store` explicitly here, since you need the
   exact rows this store holds). Zero rows, exit `0`: no pending candidates —
   that's fine, not an error. Each row is
   `<id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>`. Both
   `active` and `expired` rows are in scope for consolidation — expiry only
   ever governs `purge` eligibility, never whether a candidate can still be
   promoted. Mention any `expired` rows you did *not* end up promoting in your
   final report so the user can decide separately whether to purge them (see
   `$knowledge:remember`'s purge workflow — that is a distinct, explicit,
   destructive action this skill never performs on its own).

   `--list` shows only pending candidates; candidates a user already
   dismissed live in `<STORE_PATH>/.inbox/.dismissed/` and are out of scope
   (audit them read-only with `--list --dismissed`).

   For each candidate you intend to consider, **Read**
   `<STORE_PATH>/.inbox/<id>.md` to see its full proposed frontmatter and body
   (the `--list` row alone is not enough to judge duplication).

You now have one flat worklist of **items**, each either a *session learning*
(no stored candidate backing it) or an *inbox candidate* (backed by
`<STORE_PATH>/.inbox/<id>.md`) — this distinction only matters at apply time
(step 8): candidates get `--candidate`/`--expect-candidate`, session learnings
do not.

If the worklist is empty, say so plainly and stop — there is nothing to
consolidate this run.

## 4.5. Forward-looking retention gate, per item

Before deduping or proposing a file, classify the item:

- **Reusable going forward** — keep it in scope for CREATE/UPDATE.
- **Only session residue** — do not promote it to durable memory. For an inbox
  candidate, propose the **DISMISS** disposition (step 7) so it stops being
  counted as pending; dismissal archives it, never deletes it.
- **Historical but still explanatory** — summarize it as rationale,
  migration/provenance, or "why this rule exists"; do not store raw chronology
  or obsolete step-by-step state.
- **Superseded or obsolete** — prefer an UPDATE to the current memory with
  `status: superseded|archived|stale`, `supersedes`, and/or `review_after`
  where appropriate. An inbox candidate that is obsolete and not promoted gets
  the **DISMISS** disposition. Do not delete here; `retire` and `purge` are
  separate explicit actions.

## 5. Dedup pass, per item

For each item, gather three converging signals before judging:

1. **The MEMORY.md index** you already read in step 3.
2. **`memory-search.sh`** — the deterministic candidate set:
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-search.sh" --store <STORE_PATH> <query terms>
   ```
   Use a few keywords drawn from the item's name/description/topic. Rows are
   `<score>\t<slug>\t<type>\t<status>\t<description>`, ranked `score desc, slug
   asc`. Zero hits is a normal, valid result (exit `0`, empty stdout) — not an
   error.
3. **The `name:`/`description:` grep backstop** — a plain, read-only grep over
   the store's authoritative files (never `.inbox/`, which a bare `*.md` glob
   in the store root never reaches anyway):
   ```
   grep -n -i -E -- "name:.*<term>|description:.*<term>" "<STORE_PATH>"/*.md
   ```
   Run this as its own plain Bash step (not a plugin helper — no
   trusted-helper-grammar constraint applies to a bare `grep`). Use it to catch
   phrasing `memory-search.sh`'s tokenizer might rank low.

**Favor UPDATE over CREATE.** Treat these three signals as converging evidence,
then decide.

- If an existing file plausibly covers the same fact, decision, or how-to-work
  guidance, propose an **UPDATE** to that file. This applies even when the
  wording or scope differs, or the overlap is only partial. Extend its body, bump
  `updated:`, and adjust `tags`/`description` as needed.
- Propose **CREATE** only when no existing file is a plausible match.

This judgment call is the core value of this skill. No script can make it. A
`memory-search.sh` hit alone is never proof of duplication *or* proof of
non-duplication. **Read the candidate file's actual body** before you decide
either way. Never decide from the search row alone.

## 6. Build the full proposed diff set (before showing anything to the user)

For **every** item, before presenting anything, work out:

- **Target diff.** For CREATE: the full new file content (canonical v1
  frontmatter — `schema_version: 1`, `name`, `description`, `metadata.type`,
  `created`/`updated` as today's date, plus `tags`/`status`/etc. as
  applicable; body with `**Why:**`/`**How to apply:**` for `feedback`/
  `project` types). For UPDATE: the file's current content (its "before") and
  your proposed new content (its "after") — a plain-markdown before/after,
  never a fabricated summary.
- **Legacy upgrade, only when already updating that file.** If the UPDATE
  target is a legacy file (no `schema_version`), upgrade it to canonical v1
  **in the same diff** — never as a separate, otherwise-unmotivated edit.
  Derive `metadata.type` from its existing top-level `type:` if unambiguous;
  derive `created` from a date in the filename if one exists; otherwise stamp
  `created: unknown` **together with** `migrated: <today's ISO date>` (a
  canonical file can never carry `created: unknown` without a `migrated:`
  date — that combination is a lint ERROR). Fill `name`/`description` from the
  legacy values where present, or ask the user for a value where there is no
  deterministic source. Never upgrade a file you are not otherwise touching
  this run.
- **MEMORY.md index diff**, preserving the detected style from step 3:
  - *flat*: append the new row (or insert alphabetically if the existing rows
    are clearly alphabetically ordered; append at the end otherwise — never
    guess a fancier order).
  - *sectioned*: place the new row under the section matching the item's
    `metadata.type` or clear topical fit. If no section is an obvious fit,
    **stop and ask the user which section to use** — never invent a new
    section silently.
  - *multi-link*: when updating a row that carries cross-reference links after
    the first, only touch the first link/hook text; leave every subsequent
    `](...)` on that row untouched. A brand-new file always gets its **own**
    new row — never append it as a second link on an unrelated row.
  - Every authoritative file (old and new) must end up with **exactly one**
    first-link membership row across the whole file — never zero, never more
    than one.
- **`[[backlink]]` validation.** For every `[[slug]]` reference inside a
  proposed body (new or updated), check it against the existing authoritative
  stems plus every other slug in this same batch, using the shared resolution
  order (exact stem, then normalized fallback only when it resolves to exactly
  one real stem). An unresolved link is legal (forward-pointing links are
  allowed) but must be flagged to the user as a dangling link in the diff
  summary — never silently dropped, never silently "fixed" by guessing a
  target.
- **Sequencing rule for any proposed move/relocation/supersession.** If a diff
  would make an existing file obsolete (e.g. two items are being merged into
  one), propose the CREATE/UPDATE of the destination — including a
  `supersedes: <old-slug>` field where applicable — and stop there. **Never**
  stub, empty, or delete the old source file as part of this same run: that
  is a separate, separately-approved `retire` step (the `$knowledge:promote`
  surface, or a manual `memory-write.sh retire`, both out of this skill's
  scope) that must only run **after** the destination's `apply` has verified
  installed. Copy/write the destination before any source is ever touched —
  never a transient "original vanished" state.

## 7. Present for approval — apply nothing yet

Show the user the **complete** diff set built in step 6: every target file's
before/after (or full new content), the MEMORY.md index diff, every flagged
dangling link, every legacy upgrade you're folding in, and which items are
inbox candidates vs. session learnings. State plainly which items you judged
as UPDATE-over-CREATE and why.

Give **every inbox candidate exactly one disposition** in this same
presentation — no separate follow-up question:

- **CREATE/UPDATE** — promoted through the diff above (consumed on apply).
- **DISMISS** — reviewed and judged obsolete, duplicate, or session residue;
  it moves to `.inbox/.dismissed/` (content preserved, reversible with
  `restore`) and stops counting as pending.
- **LEAVE PENDING** — not decided this round; stays in the inbox.

For each proposed dismissal, show the candidate id, its reviewed content,
reason for dismissal, and raw SHA256. Approval binds those exact bytes.

**Apply nothing until the user has approved.** Approval covers the diffs and
the dispositions together. If the user declines some or all items, drop
exactly those from the batch — apply or dismiss only what was approved (or
nothing, if everything was declined) in step 8. A candidate that isn't
approved this round stays in the inbox untouched; mention it in the final
report as "not promoted this round," not as an error. Never dismiss a
candidate the user did not review and approve for dismissal.

## 8. Apply — one item at a time, only after approval

Process the approved items **one at a time, in sequence** — never batch two
applies against the same pre-computed hashes, because MEMORY.md's content (and
hash) changes after every successful apply. For each item:

1. **Re-Read** `<STORE_PATH>/MEMORY.md` right now (fresh — not the copy from
   step 3, which can be stale after a prior item in this same loop) and build
   this item's final MEMORY.md content from the *current* bytes.
2. **Write with the file-editing tool** (not a heredoc) the final target content to a scratch
   file — the "staged target" — and the final MEMORY.md content to another
   scratch file — the "staged index." For a CREATE, still write the staged
   target file (it's the whole new file's content).
3. Compute the CAS hashes, each its own plain, separate Bash step:
   - `--expect-index`: `shasum -a 256 "<STORE_PATH>/MEMORY.md"` (the file you
     just re-read, taken **immediately** before this apply call — not an
     earlier snapshot).
   - `--expect-target`: literal `absent` for a CREATE; otherwise
     `shasum -a 256 "<STORE_PATH>/<target>.md"` on the current file.
   - If this item is an inbox candidate: `--expect-candidate` is the **raw**
     sha256 of the whole current `<STORE_PATH>/.inbox/<id>.md` file (not the
     semantic capture key) — `shasum -a 256 "<STORE_PATH>/.inbox/<id>.md"`.
4. Invoke exactly one literal Bash segment:
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-write.sh" apply \
     --store <STORE_PATH> --target <basename>.md \
     --staged-target <scratch-target-file> --staged-index <scratch-index-file> \
     --expect-target <sha256|absent> --expect-index <sha256> \
     [--candidate <capture-id> --expect-candidate <raw-sha256>]
   ```
   Include `--candidate`/`--expect-candidate` **only** for inbox-candidate
   items; omit both for session-learning items (there is no stored candidate
   to consume).
5. Handle the exit code. **Every** mutation goes through this one call. Report
   every exit. Never work around one.

   | Code | Meaning | Required action |
   |---|---|---|
   | `0` | Success. | Report the created or updated file. For a candidate item, report that it was consumed from the inbox. Continue to the next item (back to sub-step 1). |
   | `2` | Usage error in how this skill built the call. This is a bug in this workflow, not the user's data. | Stop and report. Do not guess at a different argv. |
   | `3` | Store resolution failed. This should not happen once step 2 succeeded. | Stop and report. |
   | `4` | CAS mismatch or store-integrity failure. Something changed the store concurrently since your last read, or a candidate was tampered with. | **Do not retry blindly.** Re-read the current state. Re-run the step-6 diff for this item against the fresh content. Re-present it to the user for a fresh approval before you try again. |
   | `5` | The store is locked by a concurrent writer. | **Report the message (it names the exact `unlock` recovery command) and stop.** Never retry in a loop. Never run `unlock` yourself. That is a human decision. |
   | `6` | Reviewer-role refusal, or an unresolved fleet identity inside tmux. This is expected, correct behavior in a `*-reviewer` pane or an unnamed fleet pane. | **Relay the single stderr line verbatim and stop.** Never retry. Never work around it (for example by unsetting `KNOWLEDGE_PANE_NAME` yourself). |

**Approved dismissals** — one candidate at a time, after the approved
CREATE/UPDATE items:

1. Re-read the candidate and compute its raw sha256 immediately before the
   call: `shasum -a 256 "<STORE_PATH>/.inbox/<id>.md"`. It must match the hash
   shown in the approved disposition; otherwise stop and re-present the
   changed candidate. Use that approved hash as `--expect-candidate`.
2. Invoke exactly one literal Bash segment:
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-write.sh" dismiss \
     --store <STORE_PATH> --candidate <capture-id> --expect-candidate <raw-sha256>
   ```
3. Exit codes mean the same as for `apply`. `4` covers a changed candidate
   (re-read and re-present it) and the case where both a pending and a
   dismissed copy of the same id exist — relay it and stop; never delete
   either copy yourself. A re-run for an already-dismissed candidate with the
   same bytes is a no-op success.

If the user later wants a dismissed candidate back, the reverse is
`memory-write.sh restore` with the same `--store --candidate
--expect-candidate` arguments. It only runs on an explicit user request that
names the candidate: show its id and the raw sha256 of
`.inbox/.dismissed/<id>.md`, and pass exactly that displayed hash.

If the batch is empty (nothing was approved), skip straight to step 9 having
made zero writes.

## 9. Exit gate

Re-run the same three baseline commands from step 2:

```
bash "<PLUGIN_ROOT>/scripts/memory-lint.sh" --store <STORE_PATH>
bash "<PLUGIN_ROOT>/scripts/memory-index.sh" --store <STORE_PATH>
bash "<PLUGIN_ROOT>/scripts/memory-backlinks.sh" --store <STORE_PATH> report
```

Report the results to the user:

1. Verify that no new `ERROR`, drift, or collision findings were introduced.
   Report the result.
2. Restate any dangling links (pre-existing or newly flagged in step 6).
3. Summarize what was created and what was updated.
4. Summarize which inbox candidates were promoted, which were dismissed, and
   which were left pending.
5. Report anything the user declined.

## Non-goals (always, every run)

- Never touch `TODO.md`/`ISSUES.md`/any tracker file, in any store or
  location. A learning that came from a closed tracked item is promoted like
  any other learning through the normal capture/consolidate path — the tracker
  entry itself is never read, edited, or referenced as anything more than a
  citation inside the memory file's own body if the user wants that.
- Never write to `docs/`, `docs/decisions/`, `AGENTS.md`, or `CLAUDE.md` — that
  is the docs surface's job (`$knowledge:docs-create`), not this skill's.
- Never dismiss or restore a candidate without the user's explicit approval
  of that disposition, and never delete a dismissed candidate — dismissal is
  an archive, not a purge.
- Never retire, purge, or bootstrap a store as a side effect of consolidation
  — those are separate, explicitly user-invoked actions (`$knowledge:promote`,
  `$knowledge:remember`'s purge workflow, `$knowledge:init`).
- Never call an external service, vector DB, or embeddings API — every dedup
  signal above is local and lexical.
- Never mark this run "done" while any diff is still unapplied because of a
  `4`/`5`/`6` you haven't resolved with the user — say so explicitly instead.
