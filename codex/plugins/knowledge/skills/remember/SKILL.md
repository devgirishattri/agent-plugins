---
name: remember
description: "Capture a verified reusable lesson or user preference from the current work into the memory inbox, including implicitly when one emerges. Also list candidates or perform explicitly requested candidate cleanup."
---

# Remember

Capture may be selected implicitly during work. Listing and cleanup follow the
user's request; automatic selection never authorizes promotion, dismissal,
restoration, or purge. Run only the helper workflows below.

## Implicit capture

When a verified reusable lesson or explicit user preference emerges, stage a
candidate without asking the user to invoke this skill. Skip task status,
speculation, secrets, transcript summaries, and facts already captured. Read
plausible existing matches before adding a duplicate; use `recall` if needed.
Respect an explicit user instruction not to remember something.

Stage with the native file-editing tool outside the memory store. Under
strict-v1 use a permitted scratch file within this pane's checkout; an arbitrary
OS temporary path may fail the harness's literal-file containment check.
Use the candidate envelope below with `source: auto_capture` and a non-empty
top-level `evidence:` scalar (at most 300 bytes): an observed file/function,
commit, tool result, or short user quote. Evidence is a provenance claim, not
independent verification. Do not stage `origin_session` or `origin_pane`; the
writer supplies these from inherited runtime identity. Unknown identity stays
unknown; never set environment variables to manufacture attribution.

Call only the capture wrapper, as one literal Bash segment:

```
bash "<PLUGIN_ROOT>/scripts/memory-auto-capture.sh" [--store <path>] --staged <staged-file>
```

The wrapper screens known secret patterns and duplicates, caps candidate bytes
(`KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES`, default 4096) and per-pass count
(`KNOWLEDGE_AUTO_CAPTURE_LIMIT`, default 3). The writer enforces pending inbox
capacity (`KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING`, default 20) and pending candidates
per originating session (`KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT`, default 5).
These are pending limits, not a lifetime budget; consolidation frees capacity.
Capture tunables accept one to six decimal digits (0–999999); leading zeros
are interpreted as decimal, and other values fall back to their defaults.
The unknown-session bucket shares its limit. Never switch source/session or
fall back to manual capture to bypass a rejection. The wrapper accepts capture
arguments only; it cannot purge or promote. Report an accepted candidate briefly;
on rejection report the reason without retry loops. A zero-exit skip is not a
successful capture. Selection is best effort, not a guaranteed background hook.

## Instructions

Resolve `PLUGIN_ROOT` from this selected skill's installed absolute source path: it is the directory two levels above this `SKILL.md`. Substitute that absolute path literally in every helper invocation below; never infer it from the project working directory or hardcode a marketplace cache version.

`remember` captures a CANDIDATE learning into the memory store's inbox (`<store>/.inbox/`) for later `$knowledge:consolidate` review — it never writes MEMORY.md or a memory file directly, and a captured candidate is never indexed, recalled, or graphed until consolidation promotes it.

Determine which mode `the user's arguments` calls for:

- **`--list`** (optionally with `--expired-only`): enumerate pending candidates; add `--dismissed` to inspect retained dismissals instead. See "Listing candidates" and "Dismissed candidates" below.
- A request to delete/clean up old candidates: see "Purging candidates" (advanced, rare — only do this when the user explicitly asks).
- Anything else: **capture** the content described in `the user's arguments` (minus any `--store <path>` prefix) as a new candidate. See "Capturing a candidate" below.

Pass `--store <path>` to every Bash call below only if the user supplied one in `the user's arguments`; otherwise omit it and let the script resolve the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`, the same resolver used by `$knowledge:lint`).

### Capturing a candidate

1. Compose the staged candidate file yourself (do not ask the user to hand-write YAML). It is a strict envelope: YAML frontmatter with source, sensitivity, proposed, and optional evidence, then a markdown body. Use the file-editing tool to create it at a scratch path — never construct it via a Bash heredoc. Grammar (closed — nothing outside this shape is accepted, and the script exits `2` on any violation):
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
   - `source` is required and non-empty; it is the envelope's own provenance field (distinct from the optional `proposed.source`, which is the memory schema's own field — do not conflate them).
   - `sensitivity` is `normal` or `sensitive` — use `sensitive` for anything containing credentials, tokens, or other data the user would not want surfaced casually in recall output.
   - Under `proposed:`, only the v1 memory schema's own fields are accepted as scalars (`schema_version`, `name`, `description`, `created`, `updated`, `last_verified`, `review_after`, `status`, `confidence`, `source`, `supersedes`, `migrated`), the list field `tags`, and the one-level mapping `metadata:` (with its own scalar `type`). Omit any field you are not proposing a value for — in particular, do not include `created`/`updated` unless you have a real reason to backdate them; consolidation stamps these at promotion time.
   - Never include `capture_id`, `created`, `origin_session`, or `origin_pane` at the top level — those are writer-assigned; the script rejects them in staged input. Optional `evidence` is a non-empty single-line scalar, at most 300 bytes; it is required for `source: auto_capture`.
   - The body (after the closing `---`) becomes the candidate's proposed memory body; include `**Why:**` / `**How to apply:**` when `metadata.type` is `feedback` or `project`.

2. Run exactly one literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection):
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" [--store <path>] --staged <staged-file>
   ```
   Never invoke `memory-write.sh capture` directly — always go through `memory-remember.sh`, which derives the idempotency key the writer requires.

   - Exit `0` with `capture_id: <id>` and `created: <timestamp>`: captured. Report the id to the user; it is what `--list` and purge later reference.
   - Exit `0` with `capture_id: <id>` and `status: no-op (existing candidate unchanged)`: an identical candidate already exists (same source/sensitivity/proposed content) — this is expected on a retry, not an error.
   - Exit `2`: the staged file violated the closed envelope grammar, or duplicated a writer-assigned field — relay the stderr message, fix the staged file, and retry.
   - Exit `3`: the store could not be resolved — relay the message verbatim (it suggests `$knowledge:init` when no store exists yet).
   - Exit `4`: a store-integrity problem (e.g. `.inbox` pre-exists as something unsafe, or a colliding candidate with different content already exists under the same id) — relay the message verbatim and stop; do not attempt to fix the store yourself.
   - Exit `5`: the store is locked by a concurrent writer — relay the message (it names the exact `unlock` recovery command) and stop; do not retry in a loop.
   - Exit `6`: reviewer-role refusal, or an unresolved fleet identity inside tmux — relay the single stderr line verbatim and stop; this is expected behavior in a `*-reviewer` pane, not a bug.
   - Exit `7`: automatic-capture evidence or capacity policy refused the candidate. Report the reason; do not change source/identity or retry through a less restricted path.

### Listing candidates

Run exactly one literal Bash segment:
```
bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" [--store <path>] --list [--expired-only]
```
Output is zero or more tab-separated rows, `<id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>`, in id order. No rows (exit `0`, empty output) means no pending candidates — report that plainly rather than treating it as an error. Exit `3`/`4` mean the same store-resolution/integrity conditions as above. Present the candidates as a readable table; never fabricate a row the script did not print.

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

To undo, and only on explicit user request, run `memory-write.sh restore
--store <resolved-store-path> --candidate <id> --expect-candidate <sha256 of
.inbox/.dismissed/<id>.md>`. Dismissal never deletes; purge (below) is the
only deletion path, and it does not touch the dismissed archive.

**Rollback.** Downgrading below knowledge 0.3.30 leaves `.inbox/.dismissed/`
intact but no longer consulted: an older capture can re-queue identical
content as pending, and older listings ignore the archive. Nothing in the
archive is lost. Restore wanted candidates before downgrading. If an older
capture creates both pending and archived copies, the upgraded writer refuses
the collision; preserve both for inspection and an explicitly approved
resolution rather than attempting restore/re-dismiss blindly.

### Purging candidates

Only when the user explicitly asks to delete pending or expired candidates — this is destructive and separate from `$knowledge:consolidate`, which is the normal way candidates leave the inbox. This is a two-call PLAN/APPLY protocol on `memory-write.sh` directly (there is no purge planner script):

1. **Plan** — run exactly one literal Bash segment, choosing either `--expired` or a specific `--ids <id,...>` (comma-separated ids from the `--list` output above):
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-write.sh" purge --store <resolved-store-path> (--expired | --ids <id,...>)
   ```
   `--store` here must be the actual resolved absolute store path — `memory-write.sh` itself never falls back to a default. Use the explicit path the user gave, `$KNOWLEDGE_MEMORY_HOME` if set, or otherwise the canonical `<repo-root>/.agents/memory` (matching `$knowledge:init`'s reported target and whatever store the preceding `--list` step resolved). Save the plan's stdout (one `<id> <sha256> <created> <expired|active>` line per candidate) to a file and show it to the user verbatim; stop here if the plan is empty — there is nothing to purge.
2. **Confirm with the user** exactly which candidates to delete before proceeding — never apply without an explicit go-ahead.
3. **Apply** — run exactly one literal Bash segment with the SAME selector and the saved plan file as the manifest:
   ```
   bash "<PLUGIN_ROOT>/scripts/memory-write.sh" purge --store <same-resolved-path> (--expired | --ids <id,...>) --manifest <saved-plan-file> --confirm <same-resolved-path>
   ```
   `--confirm` must byte-equal `--store` — this restated store path IS the confirmation token. Exit `0` reports one `purged: <id>` line per deleted candidate. Exit `4` means the manifest no longer matches the live inbox (a candidate changed, or an `--expired` one is no longer expired) — relay the message and re-plan; never retry blindly with the same manifest. Exit `2`/`5`/`6` mean the same usage/lock/reviewer-refusal conditions as in capture.
