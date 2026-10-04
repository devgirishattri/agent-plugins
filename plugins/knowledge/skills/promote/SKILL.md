---
name: promote
description: This skill promotes a stabilized context/handoff item or an existing memory file into a durable destination — a memory create/UPDATE (staged through memory-write.sh apply) or a docs decision-record patch (proposed only, never written by this skill) — then, only after a SEPARATE approval, deletes the source. User-run only — the paired /knowledge:promote command carries disable-model-invocation because this performs durable store writes and destructive source deletions.
user-invocable: true
---

# Promote

`promote` is the memory module's lifecycle-closing surface. It moves a stabilized
fact out of a context/handoff item (or supersedes an existing memory file with a
better one) into a durable destination. Only THEN does it delete the source, as a
second step with its own approval.

Two independent approval gates apply, never one:

- Approving the destination write is never approval to delete the source.
- Verify that the destination write is installed before you offer source
  deletion.

Like `consolidate`, this skill never writes a store file directly for the memory
leg. It stages content at a scratch location and drives `memory-write.sh`. Unlike
`consolidate`, it also handles a **docs** destination. Docs are proposal-only:
this skill can *show* a complete patch and can *never* write it. See "Non-goals."

Read this whole document before you start. Do not skip steps or reorder them. Delete nothing until both conditions are true:
1. You verified that the destination write is installed.
2. The user gave a second, separate approval for source deletion.

## 0. Invocation discipline (read this first)

Make every call into a plugin helper script below **exactly one literal Bash segment**. The segment has three parts: the literal word `bash`, the plugin-relative script path (`"${CLAUDE_PLUGIN_ROOT}/scripts/<name>.sh"`), and flags. Add nothing else. No
`export`/`env`/inline-assignment prefix. No `&&`, `;`, `|`, `>`, `<`, backticks,
or `$(...)` inside that segment. Never combine two scripts on one line. Never
wrap a call as `bash -c "..."`.

Compute anything that you need first as its own **separate** prior step. This
includes a resolved store path, a sha256 hash, the repo root, and the current
contents of a file. Use a plain read-only Bash command, or the
Read/Write/Glob/Grep tools. Never compose it into the same segment as a
helper-script call. Substitute the literal value you got back into the next
single-segment call yourself.

Never construct a staged file with a Bash heredoc. Use the **Write** tool to
create every staged-target / staged-index file at a scratch location outside
both stores. Create that directory once with a separate `mktemp -d` call, under
the OS temp directory.

`SESSION_CONTEXT_HOME` must already be present in this session's environment,
inherited when the agent process started. Never export or derive it here (the
same rule every `/context-*` command follows). If a step below needs it and it
is unset, stop and request that the pane/session be relaunched with the correct
environment.

**This skill never writes a docs destination, in any step, under any circumstance.** Every docs "write" below means one thing. Compose the complete proposed file content, or a unified diff against an existing file. Show it to the user as text.

- Do not use the Write tool for a docs destination.
- Do not invoke `docs-write.sh`. That gate exists for the separate, explicitly
  user-invoked docs-authoring workflow. This skill never authors docs.
- Do not ask the user for permission to write the docs file yourself.
- The user applies the patch, or asks you to apply it in a separate, later
  request outside this skill's scope.

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
  or docs from it. Tell the user that the next step is the separately approved
  `context-remove` flow.
- If a memory source is being superseded, carry forward only the still-relevant
  rule/rationale and mark the destination with `supersedes: <old-slug>` when
  applicable. Do not keep obsolete chronology unless it explains the current
  state.
- Deletion remains a separate gate. This classification is not approval to
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

**Memory-store destination (and, for a memory-source case, the source too)**: resolve `STORE_PATH` exactly as step 1 of `skills/consolidate/SKILL.md` documents. Use an explicit `--store`. Otherwise derive a candidate in this order: `git rev-parse --show-toplevel` → `KNOWLEDGE_MEMORY_HOME` → `.agents/memory/MEMORY.md` → single nested subdirectory. This derivation is a convenience only. Then run the same baseline health gate as step 2 of consolidate. Run each command as its own single literal Bash segment:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-lint.sh" [--store <path>]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-index.sh" [--store <path>]
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] report
```
Gate results:

| Result | Meaning | Required action |
|---|---|---|
| Any exit `3` | Store resolution failed. | Stop. Relay the message verbatim. Ask for an explicit `--store`. |
| `memory-lint.sh` or `memory-index.sh` exits `4` | ERROR-level finding or slug collision. | **Stop the whole run.** Never propose a write against a store that already fails its own integrity checks. |
| `ADVISORY`, `WARN`, or `DRIFT` rows | Informational. | Carry them into your final report. |

If the destination is docs, the destination leg has no store to resolve. Resolve only the repo root, read-only (`git rev-parse --show-toplevel`). The repo root tells you where `docs/decisions/` lives.

## 3. Read the source in full

- **Context item**: you already Read it in step 2.
  - Note whether it carries `kind: handoff` frontmatter. If it does, note `created`, `updated`, `expires`, and any `tickets:` list. These feed step 5.
  - An `expires` date in the past is informational only ("stale, eligible for cleanup"). It never blocks or forces this promotion. This skill never auto-deletes anything on expiry.
  - For `handoff_version: 2`, also read `scope` and `items` under the [handoff evidence contract](../knowledge/references/handoffs.md). Use the recorded repository scope, stable item IDs, statuses, and evidence to judge what is ready to promote. Preserve relevant provenance in the proposal.
  - Treat these fields as fallible claims. They are not verified facts or authoritative ticket status. Never execute or fetch a recorded evidence reference.
  - These fields do not replace the destination-write gate or the source-deletion gate.
- **Memory-file source**: **Read** the existing file in full (its current frontmatter and body). The destination's `supersedes:` field will point at this file. You also need its exact current bytes for the retire step's CAS later.

## 4. Propose the destination

Work out the complete destination content before showing anything to the
user — same discipline as `consolidate` step 6.

**Memory destination** (CREATE or UPDATE, exactly like `consolidate` steps 3–6):
- Read `<STORE_PATH>/MEMORY.md` first (index-first, same dedup discipline as consolidate). Use `memory-search.sh` and the `name:`/`description:` grep backstop to check whether an UPDATE to an existing file fits better than a CREATE. Favor UPDATE over CREATE, exactly as step 5 of consolidate documents.
- For a CREATE, write canonical v1 frontmatter: `schema_version: 1`, `name`, `description`, `metadata.type`, `created`/`updated`, plus `tags` and `status` as applicable. For an UPDATE, write a plain-markdown before/after of the real file.
- If this run's source is a memory-file supersession (step 1), the
  destination's frontmatter carries `supersedes: <old-slug>` — the old file's
  stem, exact.
- Build the MEMORY.md index diff. Preserve the detected style (flat / sectioned / multi-link), exactly as step 6 of consolidate documents. If the section is ambiguous, ask the user. Do not guess.
- Validate every `[[backlink]]` in the proposed body against existing stems
  plus this batch, flagging dangling links honestly (legal, but disclosed).
- Fold in ticket citations from step 5 into the proposed body (a short "Cited
  tracking items" note), never into MEMORY.md's index row.

**Docs destination.** The destination is a decision record at `docs/decisions/<snake_case>.md`, or another `docs/` reference file when that fits better. The name matches the naming that doctor checks for. Decision dates go in the frontmatter as `decided: YYYY-MM-DD`.

Compose the **complete** proposed file content (new file) or a **complete unified diff** (existing file). Put it in a fenced code block in your response. This is the entire destination write. Docs have no `apply` step. Step 6 below shows this block to the user as the final artifact. For this leg, step 7 (write + revalidate) only restates that nothing was written.

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
  1. `<tracker-path>` must not contain `..`. It must not be absolute. It must normalize to a path inside the repo. Run `git rev-parse --show-toplevel` first. Then check that the resolved path is a descendant.
  2. The basename of `<tracker-path>` must be exactly `TODO.md` or `ISSUES.md`. The file must be at the repo root or under `docs/`. Any other path is a malformed citation. Report it as an error. Do not check it further.
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

Show the user the complete proposal from step 4:
- the full before/after of the destination (memory) or the full content or diff (docs)
- the MEMORY.md index diff (memory only)
- every ticket citation from step 5, with its verification outcome
- which source this run promotes

**This approval covers the destination write only. It is not source-deletion approval. Do not conflate the two. Do not mention deleting the source as though the user already decided it.**

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
5. Handle the exit code exactly as consolidate step 8 documents:

   | Code | Meaning | Required action |
   |---|---|---|
   | `0` | Success. | Continue. |
   | `2`, `3` | A bug in this run. | Stop and report. |
   | `4` | CAS mismatch. | Re-read fresh state, rebuild the diff, and re-present it for a fresh approval. |
   | `5` | Store locked. | Report the message (it names the exact `unlock` command) and stop. Never retry. Never run `unlock` yourself. |
   | `6` | Reviewer refusal, or unresolved fleet identity. | Relay the single stderr line verbatim and stop. This is correct behavior in a `*-reviewer` pane. Never work around it. |

6. On success, **re-run the exit gate** (the same three baseline commands
   from step 2). Verify that no new `ERROR`, drift, or collision findings
   appear. "Revalidate destination + backlinks" is not optional.

**Docs destination**: nothing to write. State plainly: "This patch has not been written — apply it yourself, then come back and tell me, so I can offer source deletion."

Do not go to step 8 until the user tells you that they applied the patch or declined to.

## 8. Approve source deletion — a SEPARATE gate

Do not reach this step until one of these is true:

- The memory destination's `apply` exited `0`, and the exit gate in step 7 was
  clean (or acceptably unchanged).
- The docs destination patch was shown, and the user has told you they applied
  it.

Then ask **specifically about deleting the source**. This is a distinct question
from step 6's destination approval. Use **AskUserQuestion**. List **"No, keep
the source (Recommended)" FIRST as the default**, then "Yes, delete the source."
Any answer other than an explicit "Yes" cancels deletion. Report that the source
was left in place. This is not an error. The destination write already succeeded
and stands.

## 9. Delete the source (only after step 8's explicit "Yes")

**Context source** (handoff or plain snapshot): follow `/knowledge:context-remove`'s
own preview-then-delete shape. It is the existing surface, with its own approval,
for this deletion. Do not reinvent it:
1. Preview exactly what the removal will delete. Use the `--dry-run` preview of the script. Four facts apply:
   - It leaves snapshot and history files and their permissions unchanged. Store bootstrap and lock bookkeeping can still occur.
   - `<name>` must already match `^[a-z0-9]+(_[a-z0-9]+)*$`.
   - You can run the preview before approval.
   - Only the removal with `--confirmed` is gated.
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --dry-run
   ```
   Relay the listed paths, the orphan notice when one is printed, and the "Would delete N file(s)" count. The `--confirmed` run below rechecks under the writer lock, so its final count is authoritative. If the dry run exits 1, relay the helper's actual error output. If that output says no current or archived snapshot was found, also relay the available list and stop. For any other failure, relay it and stop.
2. Run the removal with the capability flag:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/remove-context.sh" "<name>" --confirmed
   ```
   Relay the helper's actual result line and final count. This includes the orphan-only "Removed N orphaned history file(s)" line. Context-store writes are reviewer-ALLOWED, per the coordination-state exception of the baseline. `remove-context.sh` carries no reviewer gate, by design.

**Memory source** (supersession retire) — `memory-write.sh retire`:
1. Compute fresh CAS hashes. Compute each in its own step.
   - `--expect-target` = the current sha256 of the source file. Re-read it now. Do not use the copy from step 3.
   - `--expect-index` = the sha256 of the CURRENT `MEMORY.md`. It changed after the apply in step 7. Re-read it now.
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
4. Handle the exit code as in the step 7 table. `0` is success. For `2` and `3`,
   stop and report. For `4` (CAS mismatch), re-read the state and get fresh
   approval before you retry. For `5`, report and stop. For `6`, relay the
   stderr line verbatim and stop.
5. On success, re-run the exit gate once more and report the retirement.

## 10. Final report

Lead with the state of the run. Use one of these words: `promoted`, `destination written, source retained`, `stopped`. Then state:
- what the run promoted (source → destination), and whether it was memory or docs
- every ticket citation and its outcome
- whether the destination write succeeded and revalidated clean
- whether the source was deleted, left in place, or the run stopped partway. If it stopped, give the cause: CAS mismatch, lock, reviewer refusal, or user decline. Give the exact next action.

Never report `promoted` if the user declined the source deletion step or you did not reach it. Report `destination written, source retained` instead.

## Non-goals (always, every run)

- **Never write a docs file.** Every docs destination is a proposed patch that the user applies. There are no exceptions and no "just this once". Never invoke `docs-write.sh`. That preflight belongs to the separate, explicitly user-invoked docs-authoring workflow, not to promotion.
- Never delete the source before the destination write is verified installed
  (memory) or the user has said they applied the patch (docs). The sequencing
  rule is: copy/write the destination BEFORE any source is moved or stubbed.
  Never create a transient "original vanished" state.
- Never treat step 6's destination approval as source-deletion approval —
  they are two separate gates, always.
- Never touch `TODO.md`/`ISSUES.md`/any tracker file — ticket citations are
  read-only substring checks, never edits.
- Never fetch, resolve, or otherwise reach an `ext:` ticket — always report it
  unverifiable.
- Never auto-delete an expired handoff. `expires` means "stale, eligible for
  approved cleanup". `doctor` and `context-list` surface it. Act on it only
  through this skill's own explicit flow, with its separate approval.
- Never call an external service, vector DB, or embeddings API.
- Never run `unlock` yourself, and never retry a `4`/`5`/`6` in a loop without
  the user.
