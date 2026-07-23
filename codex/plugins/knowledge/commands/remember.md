---
description: "Capture a low-friction memory candidate into the inbox for later consolidation, list pending candidates, or purge expired ones"
argument-hint: "[--store <path>] [--list [--expired-only]] [<what to remember>]"
---

## Instructions

Resolve `PLUGIN_ROOT` from this command resource's installed absolute source path: its parent is `<plugin-root>/commands`, so go up one directory. Substitute that absolute path literally in every helper invocation below; never infer it from the project working directory or hardcode a marketplace cache version.

`remember` captures a CANDIDATE learning into the memory store's inbox (`<store>/.inbox/`) for later `$knowledge:consolidate` review — it never writes MEMORY.md or a memory file directly, and a captured candidate is never indexed, recalled, or graphed until consolidation promotes it.

Determine which mode `$ARGUMENTS` calls for:

- **`--list`** (optionally with `--expired-only`): enumerate pending candidates. See "Listing candidates" below.
- A request to delete/clean up old candidates: see "Purging candidates" (advanced, rare — only do this when the user explicitly asks).
- Anything else: **capture** the content described in `$ARGUMENTS` (minus any `--store <path>` prefix) as a new candidate. See "Capturing a candidate" below.

Pass `--store <path>` to every Bash call below only if the user supplied one in `$ARGUMENTS`; otherwise omit it and let the script resolve the store itself (explicit target > `KNOWLEDGE_MEMORY_HOME` > canonical discovery under `.agents/memory/`, the same resolver used by `$knowledge:lint`).

### Capturing a candidate

1. Compose the staged candidate file yourself (do not ask the user to hand-write YAML). It is a strict envelope: YAML frontmatter with exactly three top-level keys, then a markdown body. Use the **Write** tool to create it at a scratch path (e.g. under the OS temp directory) — never construct it via a Bash heredoc, so the single literal Bash segment rule below stays intact. Grammar (closed — nothing outside this shape is accepted, and the script exits `2` on any violation):
   ```
   ---
   source: <this session/context id — any short non-empty label, e.g. the session name>
   sensitivity: normal
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
   - Never include `capture_id` or `created` at the top level — those are writer-assigned; the script rejects a staged file containing either.
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

### Listing candidates

Run exactly one literal Bash segment:
```
bash "<PLUGIN_ROOT>/scripts/memory-remember.sh" [--store <path>] --list [--expired-only]
```
Output is zero or more tab-separated rows, `<id>\t<created>\t<age-days>\t<expired|active>\t<sensitivity>`, in id order. No rows (exit `0`, empty output) means no pending candidates — report that plainly rather than treating it as an error. Exit `3`/`4` mean the same store-resolution/integrity conditions as above. Present the candidates as a readable table; never fabricate a row the script did not print.

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

$ARGUMENTS
