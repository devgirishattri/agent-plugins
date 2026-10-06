---
name: remember
description: "Capture a verified, reusable project fact or user preference into the memory inbox. Use it on your own, without being asked, as soon as you have verified such a fact during ordinary work, including while answering a short question; the capture is inbox-only and needs no approval. Also list candidates or perform explicitly requested candidate cleanup."
---

# Remember

The agent can select capture implicitly during work. Listing and cleanup follow
the user's request. Automatic selection never authorizes promotion, dismissal,
restoration, or purge. Run only the helper workflows below.

## Implicit capture

When a verified reusable lesson or explicit user preference emerges, stage a
candidate in the same turn. This includes a fact you verified while answering a
short question. Do not wait for a wrap-up, and do not ask the user to invoke
this skill. Use only verified, durable facts.
Skip task status,
speculation, secrets, transcript summaries, and facts already captured. Read
plausible existing matches before adding a duplicate; use `recall` if needed.
Respect an explicit user instruction not to remember something.
Stage at most a few candidates per pass.

Stage with the native file-editing tool outside the memory store. Under
strict-v1, use a permitted scratch file within this pane's checkout.
An arbitrary OS temporary path can fail the harness's literal-file containment check.
Use the candidate envelope below with `source: auto_capture` and a non-empty
top-level `evidence:` scalar (one line, at most 300 bytes): an observed file/function,
commit, tool result, or short user quote. Evidence is a provenance claim, not
independent verification. The writer checks its shape, not the truth of its claim.
Do not stage `origin_session` or `origin_pane`.
The writer supplies these from inherited runtime identity. Unknown identity stays
unknown. Never set environment variables to manufacture attribution.

Call only the capture wrapper, as one literal Bash segment:

```
bash "<PLUGIN_ROOT>/scripts/memory-auto-capture.sh" [--store <path>] --staged <staged-file> [--staged <staged-file> ...]
```

Use one `--staged` argument per candidate. Never use `--batch-dir` from this skill.
After the wrapper returns, remove each staged file. Follow step 3 of "Capturing a candidate" below.

The wrapper screens known secret patterns and duplicates. It caps candidate bytes
(`KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES`, default 4096) and per-pass count
(`KNOWLEDGE_AUTO_CAPTURE_LIMIT`, default 3). The writer enforces pending inbox
capacity (`KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING`, default 20) and pending candidates
per originating session (`KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT`, default 5).
These are pending limits, not a lifetime budget. Consolidation frees capacity.
Capture tunables accept one to six decimal digits (0–999999).
Leading zeros are decimal. Other values fall back to their defaults.
The unknown-session bucket shares its limit. Never switch source/session to bypass rejection.
Never fall back to manual capture to bypass rejection.
The wrapper accepts capture arguments only. It cannot purge or promote.
Report an accepted candidate briefly. On rejection, report the reason without retry loops.
A zero-exit skip is not a
successful capture. Selection is best effort, not a guaranteed background hook.

## Instructions

Resolve `PLUGIN_ROOT` from this selected skill's installed absolute source path: it is the directory two levels above this `SKILL.md`. Substitute that absolute path literally in every helper invocation below; never infer it from the project working directory or hardcode a marketplace cache version.

`remember` captures a CANDIDATE learning into the memory store's inbox (`<store>/.inbox/`) for later `$knowledge:consolidate` review. It never writes MEMORY.md or a memory file directly. A captured candidate is never indexed, recalled, or graphed until consolidation promotes it.

Determine which mode `the user's arguments` calls for:

- **`--list`** (optionally with `--expired-only`): enumerate pending candidates; add `--dismissed` to inspect retained dismissals instead. See "Listing candidates" and "Dismissed candidates" below.
- A request to delete/clean up old candidates: see "Purging candidates" (advanced, rare; do this only when the user explicitly asks).
- Anything else: **capture** the content described in `the user's arguments` (minus any `--store <path>` prefix) as a new candidate. See "Capturing a candidate" below.

Pass `--store <path>` to every Bash call below only if the user supplied one in `the user's arguments`; otherwise omit it and let the script resolve the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`, the same resolver used by `$knowledge:lint`).

### Capturing a candidate

1. Compose the staged candidate file yourself. Do not ask the user to hand-write YAML.
   Use a strict envelope: YAML frontmatter with source, sensitivity, proposed, and optional evidence, then a markdown body.
   Use the file-editing tool to create it at a scratch path. Never construct it via a Bash heredoc.
   The grammar is closed. The script accepts only this shape and exits `2` on any violation:
   ```
   ---
   source: <this session/context id — any short non-empty label, e.g. the session name>
   sensitivity: normal
   evidence: <optional for manual capture; required when source is auto_capture>
   proposed:
     schema_version: "1"
     name: <display name>
     description: <one line>
     metadata:
       type: <user|feedback|project|reference>
     tags:
       - <kebab-case-tag>
   ---
   **Why:** <for feedback/project types>

   **How to apply:** <for feedback/project types>
   ```
   - `source` is required and non-empty. It records provenance for the candidate envelope.
     The optional `proposed.source` belongs to the proposed memory. Do not conflate them.
   - `sensitivity` is `normal` or `sensitive` — use `sensitive` for anything containing credentials, tokens, or other data the user would not want surfaced casually in recall output.
   - Under `proposed:`, only the v1 memory schema's own fields are accepted as scalars (`schema_version`, `name`, `description`, `created`, `updated`, `last_verified`, `review_after`, `status`, `confidence`, `source`, `supersedes`, `migrated`), the list field `tags`, and the one-level mapping `metadata:` (with its own scalar `type`). Omit any field you are not proposing a value for — in particular, do not include `created`/`updated` unless you have a real reason to backdate them; consolidation stamps these at promotion time.
   - Never include `capture_id`, `created`, `origin_session`, or `origin_pane` at the top level.
     The writer assigns these fields. The script rejects them in staged input.
   - Optional `evidence` is a non-empty single-line scalar, at most 300 bytes.
     It is required for `source: auto_capture`.
   - The body (after the closing `---`) becomes the candidate's proposed memory body; include `**Why:**` / `**How to apply:**` when `metadata.type` is `feedback` or `project`.

2. Run exactly one literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" [--store <path>] --staged <staged-file>
   ```
   Never invoke `memory-write.sh capture` directly — always go through `memory-remember.sh`, which derives the idempotency key the writer requires.

   Exit codes:

   | Code | Meaning | Required action |
   |---|---|---|
   | `0` with `capture_id: <id>` and `created: <timestamp>` | Captured. | Report the id to the user. `--list` and purge reference it later. |
   | `0` with `capture_id: <id>` and `status: no-op (existing candidate unchanged)` | An identical candidate already exists (same source/sensitivity/proposed content). This is expected on a retry, not an error. | Report the existing id. |
   | `2` | The staged file violated the closed envelope grammar, or duplicated a writer-assigned field. | Relay the stderr message, fix the staged file, and retry. |
   | `3` | The store could not be resolved. | Relay the message verbatim. It suggests `$knowledge:init` when no store exists yet. |
   | `4` | Store-integrity problem (for example `.inbox` pre-exists as something unsafe, or a colliding candidate with different content already exists under the same id). | Relay the message verbatim and stop. Do not fix the store yourself. |
   | `5` | The store is locked by a concurrent writer. | Relay the message (it names the exact `unlock` recovery command) and stop. Do not retry in a loop. |
   | `6` | Reviewer-role refusal, or an unresolved fleet identity inside tmux. | Relay the single stderr line verbatim and stop. This is expected behavior in a `*-reviewer` pane, not a bug. |
   | `7` | Capture-policy refusal: an `auto_capture` candidate without `evidence:`, or the pending-inbox or per-session pending cap is reached. | Relay the message and write nothing else. Do not change source/identity or use a less restricted path. Do not retry in a loop. `$knowledge:consolidate` frees capacity. |

3. Remove the staged file when the capture ends: after exit `0`, or when you stop without another attempt. Keep it while you fix it for a retry after exit `2`.
   - Remove only the staged file that you created in this run. Use one separate Bash segment for its literal path (`rm -f "<staged-file>"`). Never use a glob or a directory.
   - Never remove a file that the user named or supplied. Never remove anything inside the store. The captured candidate in `.inbox/` is the record, and it stays.
   - If `distill` composes this workflow, leave the file. Distill removes its own scratch directory.
   - If the harness or the role denies the removal, do not retry it and do not bypass the denial. If the removal fails for any reason, name the remaining path in the report.

### Listing candidates

Run exactly one literal Bash segment:
```
bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" [--store <path>] --list [--expired-only]
```
Output is zero or more tab-separated rows, `<id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>`, in id order. No rows (exit `0`, empty output) means no pending candidates. Report that plainly. It is not an error. Exit `3` and `4` mean the same store-resolution and integrity conditions as above. Present the candidates as a readable table. Never fabricate a row that the script did not print.

### Dismissed candidates

`$knowledge:consolidate` can **dismiss** a reviewed candidate (obsolete,
duplicate, or session residue) after the user approves that disposition: the
file moves to `.inbox/.dismissed/<id>.md`, keeps its content, and no longer
counts as pending, so the consolidation nudge stops reporting it. Recapturing
identical content is a no-op; different content gets a new id and is pending
again. List dismissed candidates read-only with:

```
bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" [--store <path>] --list --dismissed [--expired-only]
```

To undo a dismissal, run `memory-write.sh restore
--store <resolved-store-path> --candidate <id> --expect-candidate <sha256 of
.inbox/.dismissed/<id>.md>`. Do this only on explicit user request. Dismissal
never deletes. Purge (below) is the only deletion path, and it does not touch the
dismissed archive.

**Rollback.** Downgrading below knowledge 0.3.30 leaves `.inbox/.dismissed/`
intact but no longer consulted: an older capture can re-queue identical
content as pending, and older listings ignore the archive. Nothing in the
archive is lost. Restore wanted candidates before downgrading. If an older
capture creates both pending and archived copies, the upgraded writer refuses
the collision; preserve both for inspection and an explicitly approved
resolution rather than attempting restore/re-dismiss blindly.

**Downgrade compatibility (0.5.0).** Every new candidate — manual ones too —
carries writer-assigned `origin_session` / `origin_pane`, and can carry
`evidence`. A pre-0.5.0 reader rejects those keys. Therefore new-format inbox
candidates are NOT transparently readable after a downgrade. Before you
downgrade, consolidate, dismiss, or back up the pending inbox. Candidates written
before 0.5.0 stay valid under 0.5.0 with unchanged ids.

### Purging candidates

Run purge only when the user explicitly asks to delete pending or expired candidates.
Never run purge on your own initiative or from implicit selection.

Purge is destructive. It is separate from `$knowledge:consolidate`, the normal
way candidates leave the inbox. Purge uses a two-call PLAN/APPLY protocol on
`memory-write.sh` directly. There is no purge planner script.

1. **Plan** — run exactly one literal Bash segment, choosing either `--expired` or a specific `--ids <id,...>` (comma-separated ids from the `--list` output above):
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-write.sh" purge --store <resolved-store-path> (--expired | --ids <id,...>)
   ```
   `--store` here must be the actual resolved absolute store path — `memory-write.sh` itself never falls back to a default. Use the explicit path the user gave, `$KNOWLEDGE_MEMORY_HOME` if set, or otherwise the canonical `<repo-root>/.agents/memory` (matching `$knowledge:init`'s reported target and whatever store the preceding `--list` step resolved). Save the plan's stdout (one `<id> <sha256> <created> <expired|active>` line per candidate) to a file. Show it to the user verbatim. If the plan is empty, stop here: there is nothing to purge.
2. **Get user approval** for exactly which candidates to delete. Never apply without an explicit go-ahead.
3. **Apply** — run exactly one literal Bash segment with the SAME selector and the saved plan file as the manifest:
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-write.sh" purge --store <same-resolved-path> (--expired | --ids <id,...>) --manifest <saved-plan-file> --confirm <same-resolved-path>
   ```
   `--confirm` must byte-equal `--store`. This restated store path IS the confirmation token.

Purge exit codes:

| Code | Meaning | Required action |
|---|---|---|
| `0` | Purged. One `purged: <id>` line per deleted candidate. | Report the lines. |
| `4` | The manifest no longer matches the live inbox (a candidate changed, or an `--expired` one is no longer expired). | Relay the message and re-plan. Never retry blindly with the same manifest. |
| `2`, `5`, `6` | The same usage, lock, and reviewer-refusal conditions as in capture. | Act as in the capture table. |
