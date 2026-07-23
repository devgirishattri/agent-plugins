---
name: promote
description: This skill promotes a stabilized context/handoff item or an existing memory file into a durable destination — a memory create/UPDATE (staged through memory-write.sh apply) or a docs decision-record patch (proposed only, never written by this skill) — then, only after a SEPARATE confirmation, deletes the source. User-run only — the paired /knowledge:promote command carries disable-model-invocation because this performs durable store writes and destructive source deletions.
user-invocable: true
---

# Promote

`promote` is the memory module's lifecycle-closing surface: it moves a stabilized
fact out of a context/handoff item (or supersedes an existing memory file with a
better one) into a durable destination, and only THEN — as a second, separately
confirmed step — deletes the source. Two independent approval gates matter here,
never one: approving the destination write is never approval to delete the
source, and the destination write must be verified installed before source
deletion is even offered. Like `consolidate`, this skill never writes a store
file directly for the memory leg — it stages content at a scratch location and
drives `memory-write.sh`. Unlike `consolidate`, it also handles a **docs**
destination, and docs are proposal-only: this skill can *show* a complete
patch, and can *never* write it — see "Non-goals."

Read this whole document before starting. Do not skip steps or reorder them —
in particular, never delete anything before the destination write is verified
installed AND a second, separate confirmation for source deletion has been
given.

## 0. Invocation discipline (read this first)

Every call into a plugin helper script below is **exactly one literal Bash
segment**: the literal word `bash`, then the plugin-relative script path
(`"${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh"`), then flags — nothing else. No
`export`/`env`/inline-assignment prefix. No `&&`, `;`, `|`, `>`, `<`, backticks,
or `$(...)` inside that segment. Never combine two scripts on one line, and
never wrap a call as `bash -c "..."`.

Anything that has to be **computed** first — a resolved store path, a sha256
hash, the repo root, the current contents of a file — is its own **separate**
prior step (a plain read-only Bash command, or the Read/Write/Glob/Grep tools),
never composed into the same segment as a helper-script call. Substitute the
literal value you got back into the next single-segment call yourself.

Never construct a staged file with a Bash heredoc. Use the **Write** tool to
create every staged-target / staged-index file at a scratch location outside
both stores (a directory you create once with a separate `mktemp -d` call,
under the OS temp directory).

`SESSION_CONTEXT_HOME` must already be present in this session's environment,
inherited when the agent process started — never export or derive it here (the
same rule every `/context-*` command follows). If a step below needs it and
finds it unset, stop and request the pane/session be relaunched with the
correct environment.

**Docs destinations are never written by this skill, in any step, under any
circumstance.** Every docs "write" below means: compose the complete proposed
file content (or a unified diff against an existing file) and show it to the
user as text. Do not use the Write tool, do not invoke `docs-write.sh` (that
gate exists for the separate, explicitly user-invoked docs-authoring
workflow — this skill never authors docs), and do not ask the user for
permission to write it yourself — the user applies it, or asks you to in a
separate, later request outside this skill's scope.

## 1. Identify the source

Ask the user (or read `$ARGUMENTS`) which of these this run promotes:

- **A context-store item** — a handoff (`kind: handoff` frontmatter) or a
  plain snapshot, named by its snapshot name. Handoffs are the common case:
  they are promoted and then deleted at the end of their arc. A plain
  snapshot with a durable fact worth keeping is equally valid input.
- **An existing memory file** — a supersession source: a stabilized new memory
  file replaces an existing one (destination gets `supersedes: <old-slug>`;
  source is retired after).

If the user didn't say which, ask before doing anything else — this decision
shapes every later step.

## 1.5. Forward-looking lifecycle gate

Before proposing a destination, decide whether the source still has durable
future value:

- Promote only stabilized knowledge: current decisions, reusable learnings,
  active constraints, migration rationale, or provenance that future sessions
  must preserve.
- If a context/handoff is only stale operational residue, do not create memory
  or docs from it; tell the user the appropriate next step is the separately
  confirmed `context-remove` flow.
- If a memory source is being superseded, carry forward only the still-relevant
  rule/rationale and mark the destination with `supersedes: <old-slug>` when
  applicable. Do not keep obsolete chronology unless it explains the current
  state.
- Deletion remains a separate gate: this classification is not permission to
  delete the source.

## 2. Resolve the relevant store(s)

**Context-store source**: run
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-contexts.sh"
```
If it reports `SESSION_CONTEXT_HOME` is not set, stop and request a relaunch —
never derive another context store. If the named snapshot isn't listed, say so
and stop. Otherwise, **Read** `"$SESSION_CONTEXT_HOME/<name>.md"` directly (a
plain read — no helper needed for a single known file, same convention
`/context-remove` uses).

**Memory-store destination (and, for a memory-source case, the source too)**:
resolve `STORE_PATH` exactly as `skills/consolidate/SKILL.md` step 1 documents
(explicit `--store`, else derive candidate via `git rev-parse --show-toplevel`
→ `KNOWLEDGE_MEMORY_HOME` → `.agents/memory/MEMORY.md` → single nested
subdirectory — a convenience derivation only). Then run the same baseline
health gate as consolidate step 2, each its own single literal Bash segment:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-lint.sh" [--store <path>]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.sh" [--store <path>]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] report
```
Any exit `3`: stop, relay verbatim, ask for an explicit `--store`. `memory-lint.sh`
or `memory-index.sh` exiting `4` (ERROR-level finding or slug collision): **stop
the whole run** — never propose a write against a store that already fails its
own integrity checks. `ADVISORY`/`WARN`/`DRIFT` rows are informational — carry
them into your final report.

If the destination is docs, there is no store to resolve for the destination
leg — just the repo root (`git rev-parse --show-toplevel`), read-only, to know
where `docs/decisions/` lives.

## 3. Read the source in full

- **Context item**: you already Read it in step 2. Note whether it carries
  `kind: handoff` frontmatter. If it does, note `created`/`updated`/`expires`
  and any `tickets:` list — these feed step 5. An `expires` date in the past
  is informational only ("stale, eligible for cleanup") — it never blocks or
  forces this promotion, and this skill never auto-deletes anything on
  expiry.
- **Memory-file source**: **Read** the existing file in full (its current
  frontmatter and body) — this is what the destination's `supersedes:` will
  point at, and you need its exact current bytes for the retire step's CAS
  later.

## 4. Propose the destination

Work out the complete destination content before showing anything to the
user — same discipline as `consolidate` step 6.

**Memory destination** (CREATE or UPDATE, exactly like `consolidate` steps 3–6):
- Read `<STORE_PATH>/MEMORY.md` first (index-first, same dedup discipline as
  consolidate) and use `memory-search.sh` / the `name:`/`description:` grep
  backstop to check whether an UPDATE to an existing file is the better fit
  than a CREATE — favor UPDATE over CREATE exactly as consolidate step 5
  documents.
- Canonical v1 frontmatter for a CREATE (`schema_version: 1`, `name`,
  `description`, `metadata.type`, `created`/`updated`, plus `tags`/`status` as
  applicable); for an UPDATE, a plain-markdown before/after of the real file.
- If this run's source is a memory-file supersession (step 1), the
  destination's frontmatter carries `supersedes: <old-slug>` — the old file's
  stem, exact.
- Build the MEMORY.md index diff preserving the detected style (flat /
  sectioned / multi-link), exactly as consolidate step 6 documents — ask the
  user rather than guess a section when ambiguous.
- Validate every `[[backlink]]` in the proposed body against existing stems
  plus this batch, flagging dangling links honestly (legal, but disclosed).
- Fold in ticket citations from step 5 into the proposed body (a short "Cited
  tracking items" note), never into MEMORY.md's index row.

**Docs destination** (decision record —
`docs/decisions/<snake_case>.md`, matching the naming doctor checks for, with
decision dates in frontmatter `decided: YYYY-MM-DD`, or another `docs/`
reference file when that's the better fit): compose the **complete** proposed
file content (new file) or a **complete unified diff** (existing file) as a
fenced code block in your response. This is the entire destination write —
there is no `apply` step for docs; step 6 below shows this to the user as the
final artifact, and step 7 (write + revalidate) does nothing for this leg
except restate that nothing was written.

## 5. Ticket citations — carry through, surface honestly

If the context source carries `tickets:` (step 3), carry each citation into
the destination proposal (step 4) using the tracking-boundary grammar. For
each entry:

- `ext:<ID>` (`<ID>` matches `[A-Z][A-Z0-9]+-[0-9]+`): always report as
  **"external ticket `<ID>` — unverifiable, never fetched"**. Never attempt to
  reach it (zero network egress). A malformed `ext:` value (ID doesn't match
  the regex) is a citation error — report it, do not silently drop it.
- `local:<tracker-path>:<prefix>` (split on exactly the *second* colon —
  everything after it, verbatim, is the prefix): validate, as plain read-only
  Bash steps (no helper needed):
  1. `<tracker-path>` must not contain `..`, must not be absolute, and must
     normalize to inside the repo (`git rev-parse --show-toplevel` first,
     then check the resolved path is a descendant).
  2. `<tracker-path>`'s basename must be exactly `TODO.md` or `ISSUES.md`,
     located at the repo root or under `docs/` — any other path is a
     malformed citation, report as an error, do not check it further.
  3. The file must exist, be a regular non-symlink file (`test -f` and
     `[ ! -L ... ]`).
  4. `<prefix>` must be non-empty and single-line — an empty prefix is
     malformed (it would trivially match anything).
  5. Verify: `grep -F -q -- "<prefix>" "<tracker-path>"` (literal substring
     presence, not a regex). Report **verified** on a hit, **stale pointer**
     (WARN, not blocking) on a miss or absent file, **malformed** (error) if
     any of 1–4 failed.

Report every citation's outcome in your final proposal, even the unverifiable
and stale ones — never omit a citation because it didn't check out.

## 6. Present for approval — write nothing yet

Show the user the complete proposal from step 4: the destination's full
before/after (memory) or full content/diff (docs), the MEMORY.md index diff
(memory only), every ticket citation from step 5 with its verification
outcome, and which source this promotes. **This is destination-write approval
only — it is not source-deletion approval; do not conflate the two, and do
not mention deleting the source as though it were already decided.**

If the user declines, stop here — nothing was written, nothing was deleted.

## 7. Write the destination + revalidate

**Memory destination**: apply through the writer, one item (there is only
ever one destination per promote run):
1. **Re-Read** `<STORE_PATH>/MEMORY.md` right now (fresh, not the step-4 copy).
2. **Write** the final target content and the final MEMORY.md content to two
   scratch files (the "staged target" / "staged index").
3. Compute CAS hashes, each its own plain step: `--expect-index` = current
   `MEMORY.md`'s sha256; `--expect-target` = `absent` for a CREATE, else the
   current target file's sha256.
4. Invoke exactly one literal Bash segment:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-write.sh" apply \
     --store <STORE_PATH> --target <basename>.md \
     --staged-target <scratch-target-file> --staged-index <scratch-index-file> \
     --expect-target <sha256|absent> --expect-index <sha256>
   ```
   (No `--candidate`/`--expect-candidate` here — promote's memory destination
   is never an inbox candidate; that path belongs to `consolidate`.)
5. Handle the exit code exactly as consolidate step 8 documents: `0` success,
   continue; `2`/`3` a bug in this run, stop and report; `4` CAS mismatch —
   re-read fresh state, rebuild the diff, re-present for a fresh approval;
   `5` store locked — report the message (names the exact `unlock` command)
   and stop, never retry or run `unlock` yourself; `6` reviewer refusal or
   unresolved fleet identity — relay the single stderr line verbatim and
   stop, this is correct behavior in a `*-reviewer` pane, never work around
   it.
6. On success, **re-run the exit gate** (the same three baseline commands
   from step 2) and confirm no new `ERROR`/drift/collision findings —
   "revalidate destination + backlinks" is not optional.

**Docs destination**: nothing to write. State plainly: "This patch has not
been written — apply it yourself, then come back and confirm so I can offer
source deletion." Do not proceed to step 8 until the user has told you they
applied it (or declined to).

## 8. Confirm source deletion — a SEPARATE gate

Do not reach this step until:
- the memory destination's `apply` exited `0` and the exit gate in step 7 was
  clean (or acceptably unchanged), **or**
- the docs destination patch was shown and the user has told you they applied
  it.

Then, and only then, ask **specifically about deleting the source** — a
distinct question from step 6's destination approval. Use **AskUserQuestion**,
listing **"No, keep the source (Recommended)" FIRST as the default**, then
"Yes, delete the source." Any answer other than an explicit "Yes" cancels
deletion — report that the source was left in place (not an error; the
promotion's destination write already succeeded and stands).

## 9. Delete the source (only after step 8's explicit "Yes")

**Context source** (handoff or plain snapshot) — follow `/knowledge:context-remove`'s
own preview-then-delete shape, since that is the existing, separately
confirmed surface for this deletion (do not reinvent it):
1. Preview exactly what will be deleted:
   ```
   ls -1 "$SESSION_CONTEXT_HOME/<name>.md" "$SESSION_CONTEXT_HOME/.history/<name>."*.md 2>/dev/null
   ```
2. Run the removal with the capability flag:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --confirmed
   ```
   Relay the "N file(s) deleted" result. (Context-store writes are
   reviewer-ALLOWED per the baseline's coordination-state exception —
   `remove-context.sh` carries no reviewer gate, by design.)

**Memory source** (supersession retire) — `memory-write.sh retire`:
1. Compute fresh CAS hashes, each its own step: `--expect-target` = the
   source file's current sha256 (re-read now, not step 3's copy);
   `--expect-index` = the CURRENT `MEMORY.md`'s sha256 (it changed after
   step 7's apply — re-read it now).
2. **Write** the staged post-removal MEMORY.md content (the index with the
   source's membership row removed) to a scratch file.
3. Invoke exactly one literal Bash segment:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-write.sh" retire \
     --store <STORE_PATH> --slug <source-slug> \
     --staged-index <scratch-index-file> \
     --expect-target <sha256> --expect-index <sha256> \
     --confirm <STORE_PATH>
   ```
   (`--confirm` must byte-equal the literal `--store` value you used.)
4. Handle the exit code the same way as step 7's `apply` (`0` success; `2`/`3`
   stop and report; `4` CAS mismatch — re-read and re-confirm before retrying;
   `5` locked — report and stop; `6` reviewer refusal — relay verbatim and
   stop).
5. On success, re-run the exit gate once more and report the retirement.

## 10. Final report

State: what was promoted (source → destination), whether it was memory or
docs, every ticket citation and its outcome, whether the destination write
succeeded and revalidated clean, and whether the source was deleted, left in
place, or the whole run stopped partway (and why — CAS mismatch, lock,
reviewer refusal, or user decline). Never report "promoted" if the source
deletion step was declined or not reached — say "destination written, source
retained" instead.

## Non-goals (always, every run)

- **Never write a docs file.** Every docs destination is a proposed patch the
  user applies — no exceptions, no "just this once," no invoking
  `docs-write.sh` (that preflight belongs to the separate, explicitly
  user-invoked docs-authoring workflow, not to promotion).
- Never delete the source before the destination write is verified installed
  (memory) or the user has confirmed they applied the patch (docs) — the
  sequencing rule is copy/write destination BEFORE any source is
  moved/stubbed, never a transient "original vanished" state.
- Never treat step 6's destination approval as source-deletion approval —
  they are two separate gates, always.
- Never touch `TODO.md`/`ISSUES.md`/any tracker file — ticket citations are
  read-only substring checks, never edits.
- Never fetch, resolve, or otherwise reach an `ext:` ticket — always report it
  unverifiable.
- Never auto-delete an expired handoff — `expires` means "stale, eligible for
  confirmed cleanup," surfaced by `doctor`/`context-list`, acted on only
  through this skill's own explicit, separately confirmed flow.
- Never call an external service, vector DB, or embeddings API.
- Never run `unlock` yourself, and never retry a `4`/`5`/`6` in a loop without
  the user.
