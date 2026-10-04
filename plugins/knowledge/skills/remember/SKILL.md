---
name: remember
description: "Capture a verified, reusable project fact or user preference into the memory inbox. Use it on your own, without being asked, as soon as you have verified such a fact during ordinary work, including while answering a short question; the capture is inbox-only and needs no approval. Also list candidates or perform explicitly requested candidate cleanup."
when_to_use: "Implicitly, in the same turn, when you verify something durable that a future session would otherwise rediscover: a required command, environment setting, or invariant that you confirmed by reading or running it, or a preference the user states explicitly. This applies even when the user only asked a question or asked for a brief answer: capture first, then answer. Skip unverified claims, transient task state, and facts already in memory. Also use it when the user runs /knowledge:remember to capture, list, or clean up candidates. Never promote, dismiss, restore, or purge on your own initiative."
argument-hint: "[--store <path>] [--list [--expired-only]] [<what to remember>]"
allowed-tools: Write, Bash(bash:*)
---

# Remember

The agent can select capture implicitly during work. Listing and cleanup follow
the user's request. Automatic selection never authorizes promotion, dismissal,
restoration, or purge. Run only the helper workflows below.

## Implicit capture

When a verified reusable lesson or explicit user preference emerges, stage a
candidate in the same turn. This includes a fact you verified while answering a
short question. Do not wait for a wrap-up, and do not ask the user to invoke
this skill. Stage only high-confidence,
durable facts. Skip task status, speculation, secrets, transcript summaries, and
facts already captured. Read plausible existing matches before you add a
duplicate. Use `recall` if needed. Respect an explicit user instruction not to
remember something. Stay bounded: stage at most a few candidates per pass.

Use the candidate envelope below with `source: auto_capture` and a non-empty
top-level `evidence:` scalar (single line, at most 300 bytes). Valid evidence is
an observed file:line or function, a commit, a tool result, or a short quoted
user statement. Evidence is a provenance claim, not independent verification. The
writer checks only that evidence is present and well-formed. It never trusts or
verifies what the evidence claims. Do not stage `origin_session` or
`origin_pane`. The writer supplies these from inherited runtime identity. They
give attribution for review defaults, not authorization. Unknown identity stays
unknown. Never set environment variables to manufacture attribution.

Call only the capture wrapper, as one literal Bash segment, with one `--staged`
file per candidate (repeat `--staged` for several; never use `--batch-dir`):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-auto-capture.sh" [--store <path>] --staged <staged-file> [--staged <staged-file> ...]
```

Stage with the Write tool outside the memory store. Under strict-v1, use a permitted scratch file within this pane's checkout. An arbitrary OS temporary path can fail the harness's literal-file containment check.

The wrapper screens known secret patterns and duplicates. It caps candidate bytes
(`KNOWLEDGE_AUTO_CAPTURE_MAX_BYTES`, default 4096) and per-pass count
(`KNOWLEDGE_AUTO_CAPTURE_LIMIT`, default 3). The writer enforces pending inbox
capacity (`KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING`, default 20) and pending candidates
per originating session (`KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT`, default 5).

Capture tunables accept one to six decimal digits (0-999999). Leading zeros are read as decimal. Other values fall back to their defaults. These are pending limits, not a lifetime budget. Consolidation frees capacity. The unknown-session bucket shares its limit.

If the wrapper rejects a candidate, never switch source/session. Never fall back to manual capture to bypass the rejection. The wrapper accepts capture
arguments only. It cannot purge or promote (`--purge`/`--confirm` are rejected).
Report an accepted candidate briefly. On rejection, report the reason and do not
retry in a loop. A zero-exit skip is not a successful capture. Selection is best
effort, not a guaranteed background hook.

## Instructions

`remember` captures a CANDIDATE learning into the memory store's inbox (`<store>/.inbox/`) for later `/knowledge:consolidate` review. It never writes MEMORY.md or a memory file directly. A captured candidate is never indexed, recalled, or graphed until consolidation promotes it.

Determine which mode `$ARGUMENTS` calls for:

- **`--list`** (optionally with `--expired-only`): enumerate pending candidates. See "Listing candidates" below.
- A request to delete/clean up old candidates: see "Purging candidates" (advanced, rare; do this only when the user explicitly asks).
- Anything else: **capture** the content described in `$ARGUMENTS` (minus any `--store <path>` prefix) as a new candidate. See "Capturing a candidate" below.

Pass `--store <path>` to every Bash call below only if the user supplied one in `$ARGUMENTS`. Otherwise omit it. The script then resolves the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`). This is the same resolver that `/knowledge:lint` uses.

### Capturing a candidate

1. Compose the staged candidate file yourself. Do not ask the user to hand-write YAML.
   - The file is a strict envelope: YAML frontmatter with source, sensitivity, proposed, and optional evidence, then a markdown body.
   - Use the **Write** tool to create it at a scratch path, for example under the OS temp directory. Under the strict-v1 session-workspace harness, use a permitted scratch file inside this pane's checkout instead. An arbitrary OS temp path can fail the literal-file containment check of the harness.
   - Never construct the file with a Bash heredoc. This keeps the single literal Bash segment rule below intact.
   - The grammar is closed. The script accepts nothing outside this shape. It exits `2` on any violation:
   ```
   ---
   source: <this session/context id — any short non-empty label, e.g. the session name>
   sensitivity: normal
   evidence: <optional for manual capture; REQUIRED when source is auto_capture>
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
   - `source` is required and non-empty. It identifies the candidate envelope. `proposed.source` is a different, optional field that belongs to the proposed memory. Do not confuse them.
   - `sensitivity` is `normal` or `sensitive`. Use `sensitive` for anything that contains credentials, tokens, or other data that the user would not want surfaced casually in recall output.
   - Under `proposed:`, the script accepts only these fields:
     - scalars from the v1 memory schema: `schema_version`, `name`, `description`, `created`, `updated`, `last_verified`, `review_after`, `status`, `confidence`, `source`, `supersedes`, `migrated`
     - the list field `tags`
     - the one-level mapping `metadata:` (with its own scalar `type`)
   - Omit any field that you do not propose a value for. In particular, do not include `created` or `updated` unless you have a real reason to backdate them. Consolidation stamps these at promotion time.
   - Quoting: an **unquoted** scalar must not contain a `"` character. Otherwise the script rejects the file with `unexpected quote in unquoted scalar`. If a value contains a double quote, wrap the **whole** value in double quotes. The inner quotes then pass through as-is. Escaping them also works. Colons and apostrophes are safe unquoted. This problem occurs most often when the memory is about JSON, hook shapes, or config syntax.
   - Never include `capture_id`, `created`, `origin_session`, or `origin_pane` at the top level. The writer assigns them. The script rejects a staged file that contains any of them.
   - Optional `evidence` is a non-empty single-line scalar, at most 300 bytes. It is required for `source: auto_capture`.
   - The body (after the closing `---`) becomes the proposed memory body of the candidate. When `metadata.type` is `feedback` or `project`, include `**Why:**` and `**How to apply:**`.

2. Run exactly one literal Bash segment. Use no `export`, `env`, or assignment prefix. Do not chain, pipe, or redirect:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-remember.sh" [--store <path>] --staged <staged-file>
   ```
   Never invoke `memory-write.sh capture` directly. Always go through `memory-remember.sh`. It derives the idempotency key that the writer requires.

   Exit codes:

   | Code | Meaning | Required action |
   |---|---|---|
   | `0` with `capture_id: <id>` and `created: <timestamp>` | Captured. | Report the id to the user. `--list` and purge reference it later. |
   | `0` with `capture_id: <id>` and `status: no-op (existing candidate unchanged)` | An identical candidate already exists (same source/sensitivity/proposed content). This is expected on a retry, not an error. | Report the existing id. |
   | `2` | The staged file violated the closed envelope grammar, or duplicated a writer-assigned field. | Relay the stderr message, fix the staged file, and retry. |
   | `3` | The store could not be resolved. | Relay the message verbatim. It suggests `/knowledge:init` when no store exists yet. |
   | `4` | Store-integrity problem (for example `.inbox` pre-exists as something unsafe, or a colliding candidate with different content already exists under the same id). | Relay the message verbatim and stop. Do not fix the store yourself. |
   | `5` | The store is locked by a concurrent writer. | Relay the message (it names the exact `unlock` recovery command) and stop. Do not retry in a loop. |
   | `6` | Reviewer-role refusal, or an unresolved fleet identity inside tmux. | Relay the single stderr line verbatim and stop. This is expected behavior in a `*-reviewer` pane, not a bug. |
   | `7` | Capture-policy refusal: an `auto_capture` candidate without `evidence:`, or the pending-inbox or per-session pending cap is reached. | Relay the message and write nothing else. Do not retry in a loop. `/knowledge:consolidate` frees capacity. |

### Listing candidates

Run exactly one literal Bash segment:
```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-remember.sh" [--store <path>] --list [--expired-only]
```
Output is zero or more tab-separated rows in id order: `<id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>`. No rows (exit `0`, empty output) means no pending candidates. Report that plainly. It is not an error. Exit `3` and `4` mean the same store-resolution and integrity conditions as above. Present the candidates as a readable table. Never fabricate a row that the script did not print.

### Dismissed candidates

`/knowledge:consolidate` can **dismiss** a reviewed candidate (obsolete, duplicate, or session residue) after the user approves that disposition. The file moves to `.inbox/.dismissed/<id>.md` and keeps its content. It no longer counts as pending, so the consolidation nudge stops reporting it. Recapturing identical content is a no-op. Different content gets a new id and is pending again. List dismissed candidates read-only with:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-remember.sh" [--store <path>] --list --dismissed [--expired-only]
```

To undo a dismissal, run `memory-write.sh restore
--store <resolved-store-path> --candidate <id> --expect-candidate <sha256 of
.inbox/.dismissed/<id>.md>`. Do this only on explicit user request. Dismissal
never deletes. Purge (below) is the only deletion path, and it does not touch the
dismissed archive.

**Rollback.** Before you downgrade below knowledge 0.3.30, `restore` any
dismissed candidate that you still want pending. An older release leaves
`.inbox/.dismissed/` intact but ignores it. Its capture can re-queue identical
content as pending, and its listings do not show the archive. If both a
pending and a dismissed copy of the same id exist after you upgrade again, the
writer refuses `dismiss`/`restore` for that id (collision). Keep both copies for
inspection and resolve them explicitly. Never delete either copy
automatically.

**Downgrade compatibility (0.5.0).** Every new candidate — manual ones too —
carries writer-assigned `origin_session` / `origin_pane`, and can carry
`evidence`. A pre-0.5.0 reader rejects those keys. Therefore new-format inbox
candidates are NOT transparently readable after a downgrade. Before you
downgrade, consolidate, dismiss, or back up the pending inbox. Candidates written
before 0.5.0 stay valid under 0.5.0 with unchanged ids.

### Purging candidates

**Condition:** run purge only when the user explicitly asks to delete pending or expired candidates. Never run purge on your own initiative or from implicit selection.

**Note:** purge is destructive. It is separate from `/knowledge:consolidate`, which is the normal way candidates leave the inbox. Purge is a two-call PLAN/APPLY protocol on `memory-write.sh` directly. There is no purge planner script.

1. **Plan.** Run exactly one literal Bash segment. Choose either `--expired` or a specific `--ids <id,...>` (comma-separated ids from the `--list` output above):
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-write.sh" purge --store <resolved-store-path> (--expired | --ids <id,...>)
   ```
   `--store` here must be the actual resolved absolute store path. `memory-write.sh` itself never falls back to a default. Use the first of these that applies:
   1. the explicit path the user gave
   2. `$KNOWLEDGE_MEMORY_HOME`, if set
   3. the canonical `<repo-root>/.agents/memory`

   This path matches the target that `/knowledge:init` reported and the store that the preceding `--list` step resolved.

   Save the stdout of the plan to a file. It has one `<id> <sha256> <created> <expired|active>` line per candidate. Show it to the user verbatim. If the plan is empty, stop here. There is nothing to purge.
2. **Get user approval** for exactly which candidates to delete. Never apply without an explicit go-ahead.
3. **Apply.** Run exactly one literal Bash segment. Use the SAME selector. Use the saved plan file as the manifest:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-write.sh" purge --store <same-resolved-path> (--expired | --ids <id,...>) --manifest <saved-plan-file> --confirm <same-resolved-path>
   ```
   `--confirm` must byte-equal `--store`. This restated store path IS the confirmation token.

Purge exit codes:

| Code | Meaning | Required action |
|---|---|---|
| `0` | Purged. One `purged: <id>` line per deleted candidate. | Report the lines. |
| `4` | The manifest no longer matches the live inbox (a candidate changed, or an `--expired` one is no longer expired). | Relay the message and re-plan. Never retry blindly with the same manifest. |
| `2`, `5`, `6` | The same usage, lock, and reviewer-refusal conditions as in capture. | Act as in the capture table. |

$ARGUMENTS
