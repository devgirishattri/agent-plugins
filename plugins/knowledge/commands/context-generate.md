---
description: Generate a session context summary — what you worked on, decisions made, where you left off
argument-hint: "[snapshot-name] [--handoff] [--expires <UTC-ISO>]"
allowed-tools: Read, Glob, Grep, Bash(bash:*)
---

## Instructions

Generate a concise summary of what THIS session has been working on — for handing off to another session.

0. **Handoff flags (optional, Phase E)**: `$ARGUMENTS` may include `--handoff` and/or `--expires <UTC-ISO>` after the snapshot name, in either order (e.g. `foo --handoff`, `foo --handoff --expires 2026-08-15T00:00:00Z`, `foo --expires ... --handoff`). Parse these out of `$ARGUMENTS` before deriving the snapshot name in step 1 — they are flags for the save step (step 4), not part of the name.
   - `--handoff` marks this snapshot as a **structured handoff**: a running item or resumable endpoint, promoted then deleted at the end of its arc (see `docs/KNOWLEDGE_PLUGIN_SPEC.md` "Handoff" in the taxonomy table), instead of an ordinary point-in-time snapshot. Use it when the session is handing off unfinished, resumable work — not for a routine end-of-session summary.
   - `--expires <UTC-ISO>` sets an explicit expiry (`YYYY-MM-DDTHH:MM:SSZ`); only meaningful together with `--handoff`. Omit it to get the default of `created + 14 days`. `expires` means "stale, eligible for confirmed cleanup" — it is never silently deleted by anything.
   - Without `--handoff`, this command's output is byte-identical to its pre-Phase-E behavior on a plain snapshot. Re-running it without `--handoff` against a snapshot name that is **already** a handoff **refuses** (`save-context.sh` exits 2 with the single stderr line `handoff exists: re-run with --handoff`) rather than silently mutating or dropping its metadata — if you hit this, tell the user and re-run with `--handoff`.
   - Regenerating an existing handoff with `--handoff` again is a normal **update**: it keeps the original `created` date, advances `updated` to now, and keeps the existing `expires` unless `--expires` is given this time (which replaces it). Regenerating an existing **plain** snapshot with `--handoff` **upgrades** it (its `created` becomes now, since a plain snapshot carries no prior metadata to preserve).

1. **Determine snapshot name**: Use $ARGUMENTS (with the handoff flags above removed) if provided, otherwise derive from the Claude session name or current directory name.

2. **Gather session context** by checking:
   - `git diff --stat HEAD` — files currently modified
   - `git log --oneline -10` — recent commits in this session
   - `git diff --name-only HEAD~5..HEAD` — files changed in last 5 commits
   - Any `docs/TODO.md` or `docs/ISSUES.md` — tracked items
   - Any open problems or blockers encountered during the conversation

3. **Generate the summary** with these sections (include only what's relevant):

   ```
   # Session Context: <name>
   Generated: YYYY-MM-DD HH:MM
   Project: <current directory>

   ## What Was Done
   [Bullet list of completed work — features added, bugs fixed, refactors made]

   ## Files Changed
   [List of files modified/created/deleted with brief description]

   ## Key Decisions
   [Decisions made during the session and WHY — these are the hardest to reconstruct]

   ## Open Issues
   [Problems discovered, unresolved bugs, things that need attention]

   ## Where I Left Off
   [Current state — what's in progress, what the next step should be]

   ## Notes for Next Session
   [Gotchas, context that isn't obvious from the code, warnings]
   ```

   **If this is a handoff (`--handoff` was given) and the session cites tracking items** (a `TODO.md`/`ISSUES.md` entry or an external ticket) worth resurfacing at promotion time, prepend a minimal frontmatter fence to the temp file in step 4 — **before** the `# Session Context: <name>` line — containing only a `tickets:` list, one item per line, each prefixed `  - `:
   ```
   ---
   tickets:
     - ext:<ID>
     - local:<tracker-path>:<entry-text prefix>
   ---
   # Session Context: <name>
   ...
   ```
   `ext:<ID>` cites an external ticket (`<ID>` matching `[A-Z][A-Z0-9]+-[0-9]+`) — always reported unverifiable, never fetched. `local:<tracker-path>:<prefix>` cites a repo tracker file (`TODO.md`/`ISSUES.md` at the repo root or under `docs/`); everything after the *second* colon is the verbatim, non-empty, single-line prefix to look for in that file — do not add a third colon or split differently. This fence is **the only** frontmatter a caller may stage — `save-context.sh` computes every other handoff field itself and rejects any other staged key. Omit the fence entirely when there is nothing to cite; it is never required.

4. **Save the snapshot**: Write it to a temp file, then run the helper. `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started (the pane/session launcher sets it — never export or derive it here). Run exactly one Bash segment, with no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-context.sh" "<snapshot-name>" "<temp-file>" [--handoff] [--expires <UTC-ISO>]
   ```
   Include `--handoff`/`--expires` only when step 0 found them in `$ARGUMENTS`; omit both for a plain snapshot (byte-identical to the pre-Phase-E call).
   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request that this pane/session be relaunched with the correct environment instead of deriving another context store.
   If a snapshot with the same name already exists, the previous version is archived
   automatically to `$SESSION_CONTEXT_HOME/.history/` (the 10 most recent versions are kept).
   Compare versions later with `/context-diff <snapshot-name>`.
   - Exit `2` with stderr `handoff exists: re-run with --handoff`: you omitted `--handoff` against a snapshot that already is one. Relay this to the user and re-run step 4 with `--handoff` added — never retry by adding `--handoff` silently without saying so, since that changes what gets written.
   - Any other non-zero exit (bad `--expires` format, unknown flag, or a genuine store error): relay the script's stderr verbatim and stop; do not guess at a different invocation.

5. **Report**: "Session context saved as '<snapshot-name>'. Share with `/context-share <session> <snapshot-name>` or load later with `/context-load <snapshot-name>`." If a previous version was archived, mention `/context-diff <snapshot-name>` to see what changed. If this was a handoff, also state its `expires` date and that `/knowledge:promote` is how it eventually gets promoted and its source deleted — expiry only ever marks it stale/eligible for confirmed cleanup, it is never silently deleted.

Keep the summary **concise** — under 150 lines. Focus on what another session needs to continue the work, not a transcript of everything that happened.
