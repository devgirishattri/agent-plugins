---
name: consolidate
description: This skill drains the memory capture inbox and this session's learnings into reviewed create/update diffs against MEMORY.md, applying nothing until the user approves every diff. User-run only — the paired /knowledge:consolidate command carries disable-model-invocation because this performs durable store writes.
user-invocable: true
---

# Consolidate

`consolidate` is the memory module's core value. It turns an inbox of low-friction
captures, plus whatever came up this session, into reviewed, deterministic
plain-markdown diffs against the memory store. It applies them **only** through
`memory-write.sh apply`, after the user has approved every single diff.

You make the most important judgment call: propose an **UPDATE** to an existing
file, not a new one, whenever a plausible match exists. No script makes it for
you. The writer does everything else (locking, CAS, reviewer refusal, candidate
consumption). This skill never writes a store file directly. It stages content
at a scratch location and drives `memory-write.sh`.

Read this whole document before you start. Do not skip steps or reorder them.
Never apply anything before the user has seen and approved the complete diff set
(step 7). Never propose a fix for anything outside `.agents/memory/`. Docs,
TODO/ISSUES trackers, and context snapshots are other surfaces' jobs (see
"Non-goals" at the end).

`distill` can compose this workflow for a user-directed session wrap-up. The
user then approves the same complete target/index diffs and candidate
dispositions within Distill's batch. That approval is sufficient. No second
invocation or duplicate approval is needed. All baseline, role, CAS, and exit
gates still apply.

When you review candidates, show each candidate's `evidence:` and writer-assigned
`origin_session` / `origin_pane` (see step 4). Attribution is not authorization.
It does not establish truth. Evidence is a provenance claim that the writer never
verified.

**Compatibility note:** 0.5.0 candidates carry `origin_session` / `origin_pane`
(and optionally `evidence`). A pre-0.5.0 reader rejects them. Before a downgrade,
consolidate or dismiss (or back up) the pending inbox. Rollback is not
transparent for new-format candidates.

## 0. Invocation discipline (read this first)

Make every call into a plugin helper script below **exactly one literal Bash segment**. The segment has three parts: the literal word `bash`, the plugin-relative script path (`"${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh"`), and flags. Add nothing else. No
`export`/`env`/inline-assignment prefix. No `&&`, `;`, `|`, `>`, `<`, backticks,
or `$(...)` inside that segment. Never combine two scripts on one line. Never
wrap a call as `bash -c "..."`. That is not a recognized helper invocation. It
defeats the single-literal-segment rule.

Compute anything that you need first as its own **separate** prior step. This
includes a resolved store path, a sha256 hash, the repo root, and the current
contents of a file. Use a plain read-only Bash command like
`git rev-parse --show-toplevel` or `shasum -a 256 <file>`, or the
Read/Write/Glob/Grep tools. Never compose it into the same segment as a
helper-script call. Substitute the literal value you got back into the next
single-segment call yourself.

Never construct a staged file with a Bash heredoc. Use the **Write** tool to
create every staged-target / staged-index file at a scratch location outside
the store. For example, create a directory once with a separate `mktemp -d`
call, under the OS temp directory. This keeps every helper invocation a single
literal segment. It also keeps the store itself untouched by anything but the
writer.

## 1. Resolve the store

If the user (or `$ARGUMENTS`) gave an explicit `--store <path>`, that is your
`STORE_PATH` — skip to step 2.

Otherwise, derive a candidate path yourself, mirroring (not replacing) the
spec's canonical discovery algorithm, using only plain read-only commands, each
its own step:

1. Run `git rev-parse --show-toplevel`. The result is `REPO_ROOT`. If the command fails, you are not inside a git repository. Stop and tell the user. There is nothing to resolve.
2. Check `KNOWLEDGE_MEMORY_HOME` in the current environment (a plain
   `echo "${KNOWLEDGE_MEMORY_HOME:-}"`). If set and non-empty, that is your
   candidate `STORE_PATH`.
3. Otherwise check whether `<REPO_ROOT>/.agents/memory/MEMORY.md` exists (a
   plain `test -f` / Glob check). If it does, `STORE_PATH` =
   `<REPO_ROOT>/.agents/memory`.
4. Otherwise enumerate the immediate subdirectories of
   `<REPO_ROOT>/.agents/memory` (a plain `find <dir> -mindepth 1 -maxdepth 1
   -type d`) and check each for a `MEMORY.md`. If **exactly one** has one, that
   subdirectory is your candidate `STORE_PATH`. If zero or more than one do,
   you have no candidate. Go to step 2 anyway and omit `--store`. The error message of the real resolver is authoritative.

This derivation is a convenience only. It is never the authority. The next step (baseline health) runs the real, single implementation of this algorithm: `km_resolve_store` in `lib.sh`, shared by every helper script. Its exit code decides whether you have a usable store. If your candidate and the real resolver disagree, the real resolver wins. Stop and ask. Do not guess further.

## 2. Baseline health gate

Run all three commands. Run each as its own single literal Bash segment. Pass `--store "<STORE_PATH>"` if you derived one in step 1. Omit it if you did not:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-lint.sh" [--store <path>]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.sh" [--store <path>]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] report
```

Gate results:

| Command and exit code | Meaning | Required action |
|---|---|---|
| Any of the three exits `3` | Store resolution failed (not found, or ambiguous; the message lists every candidate). | **Stop.** Relay the message verbatim. Ask the user for an explicit `--store <path>`, or point at `/knowledge:init` if no store exists at all. Do not guess. |
| `memory-lint.sh` exits `4` | At least one `ERROR`-level finding: a schema violation, unparseable frontmatter, or a slug collision. | **Stop the whole run.** Report every `ERROR` row. Do not propose any diffs against a store that already fails its own integrity checks. The user (or `/knowledge:lint` directly) must fix these first. |
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
- **multi-link** — some rows carry more than one `](...)` link on the same line. The first link is membership. Any further links are cross-references. This style can coexist with either flat or sectioned.
- **degenerate** — free prose with no index rows at all, or index rows mixed with inline knowledge prose. `memory-lint.sh` and `memory-index.sh` already flagged this as ADVISORY in step 2. If they did, propose a minimal index skeleton, or an extraction of the inline prose into its own file. Put the proposal in the same diff batch in step 6. Use flat style unless the surrounding content clearly implies sections.

## 4. Gather inputs

Two sources, both in scope for this run:

1. **Session learnings** — anything `$ARGUMENTS` supplied, plus anything from
   this conversation that reads as a durable learning, decision, or
   how-to-work feedback worth persisting. Use judgment: don't invent a
   learning that didn't happen, and don't propose a diff for ephemeral
   chatter that isn't durable knowledge. Treat a learning that traces back to a closed TODO/ISSUES/ticket item like any other learning. See "Non-goals" below for the hard rule: never touch the tracker file itself.
2. **Inbox candidates** — run:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-remember.sh" --store <STORE_PATH> --list
   ```
   (always pass the resolved `--store` explicitly here, since you need the
   exact rows this store holds). Zero rows, exit `0`: no pending candidates —
   that's fine, not an error. Each row is
   `<id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>`. Both
   `active` and `expired` rows are in scope for consolidation. Expiry governs only `purge` eligibility. It never decides whether a candidate can still be promoted. In your final report, list each `expired` row that you did *not* promote. The user then decides separately whether to purge it. See the purge workflow of `/knowledge:remember`. Purge is a distinct, explicit, destructive action. This skill never performs it on its own.

   `--list` shows only pending candidates; candidates a user already
   dismissed live in `<STORE_PATH>/.inbox/.dismissed/` and are out of scope
   (audit them read-only with `--list --dismissed`).

   For each candidate you intend to consider, **Read** `<STORE_PATH>/.inbox/<id>.md`. This shows its full proposed frontmatter and body. The `--list` row alone is not enough to judge duplication.

   **Evidence and origin.** In the review step, display the `evidence:` of each candidate. Older and manual candidates have none. Say so when it is absent. Also display `origin_session` and `origin_pane`. Pre-0.5.0 candidates have none. Treat those candidates as unattributed.

   Ordinary explicit consolidation keeps its full-inbox scope. Selection by origin applies only when `distill` composes this workflow:
   - Select candidates whose `origin_session` matches the inherited session ID.
   - Read the session ID with the single read-only Bash segment `printenv CLAUDE_CODE_SESSION_ID`. Never set or export it.
   - Candidates with a missing, `unknown`, or foreign origin stay pending, unless the user explicitly selects them.

   Selection only narrows what you propose. The approval contract in step 7 is unchanged. `origin_*` is attribution, not authorization.

You now have one flat worklist of **items**. Each item is either a *session learning* (no stored candidate backs it) or an *inbox candidate* (`<STORE_PATH>/.inbox/<id>.md` backs it). The difference matters only at apply time (step 8). Candidates get `--candidate` and `--expect-candidate`. Session learnings do not.

If the worklist is empty, say so plainly and stop. There is nothing to consolidate this run.

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
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-search.sh" --store <STORE_PATH> <query terms>
   ```
   Use a few keywords drawn from the item's name/description/topic. Rows are
   `<score>\t<slug>\t<type>\t<status>\t<description>`, ranked `score desc, slug
   asc`. Zero hits is a normal, valid result (exit `0`, empty stdout) — not an
   error.
3. **The `name:`/`description:` grep backstop** — a plain, read-only grep over the authoritative files of the store. Never grep `.inbox/`. A bare `*.md` glob in the store root never reaches it anyway:
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

- **Target diff.**
  - For CREATE: the full new file content. Use canonical v1 frontmatter: `schema_version: 1`, `name`, `description`, `metadata.type`, and `created`/`updated` as today's date. Add `tags`, `status`, and similar fields as applicable. For the `feedback` and `project` types, the body needs `**Why:**` and `**How to apply:**`.
  - For UPDATE: the file's current content (its "before") and your proposed new content (its "after"). Use a plain-markdown before/after. Never write a fabricated summary.
- **Legacy upgrade, only when already updating that file.** If the UPDATE
  target is a legacy file (no `schema_version`), upgrade it to canonical v1 **in the same diff**. Never make the upgrade a separate, otherwise-unmotivated edit.
  - Derive `metadata.type` from its existing top-level `type:` if that is unambiguous.
  - Derive `created` from a date in the filename if one exists.
  - Otherwise stamp `created: unknown` **together with** `migrated: <today's ISO date>`. A canonical file can never carry `created: unknown` without a `migrated:` date. That combination is a lint ERROR.
  - Fill `name` and `description` from the legacy values where present. Where no deterministic source exists, ask the user for a value.
  - Never upgrade a file you are not otherwise touching this run.
- **MEMORY.md index diff**, preserving the detected style from step 3:
  - *flat*: append the new row. If the existing rows are clearly in alphabetical order, insert the row alphabetically. Otherwise append at the end. Never guess a fancier order.
  - *sectioned*: place the new row under the section matching the item's
    `metadata.type` or clear topical fit. If no section is an obvious fit,
    **stop and ask the user which section to use** — never invent a new
    section silently.
  - *multi-link*: when you update a row that carries cross-reference links after the first, touch only the first link and hook text. Leave every subsequent `](...)` on that row untouched. A brand-new file always gets its **own** new row. Never append it as a second link on an unrelated row.
  - Every authoritative file (old and new) must end up with **exactly one** first-link membership row across the whole index. Never zero. Never more than one.
- **`[[backlink]]` validation.** For every `[[slug]]` reference inside a proposed body (new or updated), check it against the existing authoritative stems plus every other slug in this same batch. Use the shared resolution order: exact stem first. Use the normalized fallback only when it resolves to exactly one real stem.
  - An unresolved link is legal, because forward-pointing links are allowed.
  - Flag it to the user as a dangling link in the diff summary.
  - Never drop it silently. Never "fix" it by guessing a target.
- **Sequencing rule for any proposed move, relocation, or supersession.** Use this rule when a diff would make an existing file obsolete (for example, when two items merge into one).
  - Propose the CREATE or UPDATE of the destination. Include a `supersedes: <old-slug>` field where applicable. Stop there.
  - **Never** stub, empty, or delete the old source file in this same run. That is a separate, separately-approved `retire` step. The `/knowledge:promote` surface or a manual `memory-write.sh retire` performs it. Both are out of scope for this skill. The `retire` step runs only **after** the `apply` of the destination has verified as installed.
  - Write the destination before you touch any source. This avoids a transient "original vanished" state.

## 7. Present for approval — apply nothing yet

Show the user the **complete** diff set built in step 6. Include:
- every target file's before/after (or full new content)
- the MEMORY.md index diff
- every flagged dangling link
- every legacy upgrade you are folding in
- which items are inbox candidates and which are session learnings

State plainly which items you judged as UPDATE-over-CREATE, and why.

Give **every inbox candidate exactly one disposition** in this same
presentation — no separate follow-up question:

- **CREATE/UPDATE** — promoted through the diff above (consumed on apply).
- **DISMISS** — reviewed and judged obsolete, duplicate, or session residue;
  it moves to `.inbox/.dismissed/` (content preserved, reversible with
  `restore`) and stops counting as pending. For each proposed dismissal, show the candidate id, the reviewed content (or a faithful summary), the reason, and its **raw sha256**. Take the hash with `shasum -a 256 "<STORE_PATH>/.inbox/<id>.md"` when you read the candidate for review. The user approves that displayed hash.
- **LEAVE PENDING** — not decided this round; stays in the inbox.

**Apply nothing until the user has approved.** Approval covers the diffs and the dispositions together.

If the user declines some or all items, drop exactly those items from the batch. In step 8, apply or dismiss only what the user approved. If the user declined everything, apply nothing.

A candidate that the user did not approve this round stays in the inbox untouched. In the final report, list it as "not promoted this round". Do not report it as an error. Never dismiss a candidate that the user did not review and approve for dismissal.

## 8. Apply — one item at a time, only after approval

Process the approved items **one at a time, in sequence**. Never batch two applies against the same pre-computed hashes. MEMORY.md's content (and hash) changes after every successful apply. For each item:

1. **Re-Read** `<STORE_PATH>/MEMORY.md` now. Do not use the copy from step 3. It can be stale after a prior item in this same loop. Build this item's final MEMORY.md content from the *current* bytes.
2. **Write** the final target content to a scratch file, the "staged target". Write the final MEMORY.md content to another scratch file, the "staged index". Use the Write tool, not a heredoc. For a CREATE, still write the staged target file. It holds the new file's whole content.
3. Compute the CAS hashes, each its own plain, separate Bash step:
   - `--expect-index`: `shasum -a 256 "<STORE_PATH>/MEMORY.md"` (the file you
     just re-read, taken **immediately** before this apply call — not an
     earlier snapshot).
   - `--expect-target`: literal `absent` for a CREATE; otherwise
     `shasum -a 256 "<STORE_PATH>/<target>.md"` on the current file.
   - If this item is an inbox candidate, compute `--expect-candidate`. It is the **raw** sha256 of the whole current `<STORE_PATH>/.inbox/<id>.md` file, not the semantic capture key: `shasum -a 256 "<STORE_PATH>/.inbox/<id>.md"`.
4. Invoke exactly one literal Bash segment:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-write.sh" apply \
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

1. Use the **approved** raw sha256 shown in step 7 as `--expect-candidate`. Re-hash the file immediately before the call. If the current hash differs from the approved one, the candidate changed after review. Stop. Re-present it for a fresh approval. Never substitute a freshly computed hash for the approved one.
2. Invoke exactly one literal Bash segment:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-write.sh" dismiss \
     --store <STORE_PATH> --candidate <capture-id> --expect-candidate <raw-sha256>
   ```
3. Exit codes mean the same as for `apply`.
   - `4` covers two cases. In the first, the candidate changed: re-read it and re-present it. In the second, both a pending copy and a dismissed copy of the same id exist: relay the message and stop. Never delete either copy yourself.
   - A re-run for an already-dismissed candidate with the same bytes is a no-op success.

If the user later wants a dismissed candidate back, the reverse is `memory-write.sh restore` with the same `--store --candidate --expect-candidate` arguments. Run it only on an explicit user request that names the candidate. Show its id and the raw sha256 of `.inbox/.dismissed/<id>.md`. Pass exactly that displayed hash.

If the batch is empty (nothing was approved), skip straight to step 9 having
made zero writes.

## 9. Exit gate

Re-run the same three baseline commands from step 2:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-lint.sh" --store <STORE_PATH>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.sh" --store <STORE_PATH>
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" --store <STORE_PATH> report
```

Report the results to the user. Lead with the overall state. Use these outcome words for each item: `applied`, `dismissed`, `left pending`, `declined`, `failed`. If any diff is still unapplied, the state is not done. Name the exit code and the exact next action.

1. Verify that no new `ERROR`, drift, or collision findings were introduced.
   Report the result.
2. Restate any dangling links (pre-existing or newly flagged in step 6).
3. Summarize what was created and what was updated.
4. Summarize which inbox candidates were promoted, which were dismissed, and
   which were left pending.
5. Report anything the user declined.

## Non-goals (always, every run)

- Never touch `TODO.md`, `ISSUES.md`, or any tracker file, in any store or location. Promote a learning that came from a closed tracked item like any other learning, through the normal capture and consolidate path. Never read or edit the tracker entry itself. Reference it only as a citation inside the body of the memory file, and only if the user wants that.
- Never write to `docs/`, `docs/decisions/`, `AGENTS.md`, or `CLAUDE.md` — that
  is the docs surface's job (`/knowledge:docs-create`), not this skill's.
- Never dismiss or restore a candidate without the explicit user approval of that disposition. Never delete a dismissed candidate. Dismissal is an archive, not a purge.
- Never retire, purge, or bootstrap a store as a side effect of consolidation
  — those are separate, explicitly user-invoked actions (`/knowledge:promote`,
  `/knowledge:remember`'s purge workflow, `/knowledge:init`).
- Never call an external service, vector DB, or embeddings API — every dedup
  signal above is local and lexical.
- Never mark this run "done" while a diff is still unapplied because of an exit `4`, `5`, or `6`. Resolve the exit with the user first. Otherwise say so explicitly.
