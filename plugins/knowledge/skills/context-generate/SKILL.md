---
name: context-generate
description: Generate and save a session context snapshot (what was worked on, decisions, where you left off); --handoff produces a structured v2 handoff with expiry.
when_to_use: User asks to save, snapshot, hand off, or write up the session state for a later session or another pane ("save my context", "generate a handoff", "capture where we are").
argument-hint: "[snapshot-name] [--handoff] [--expires <UTC-ISO>]"
allowed-tools: Read, Glob, Grep, Bash(bash:*)
---

## Instructions

Summarize what THIS session worked on, so that another session can continue the work.

0. **Parse the handoff flags (optional).** `$ARGUMENTS` can include `--handoff` and `--expires <UTC-ISO>` after the snapshot name, in either order. Examples: `foo --handoff`, `foo --handoff --expires 2026-08-15T00:00:00Z`, `foo --expires ... --handoff`. Remove these flags from `$ARGUMENTS` before you derive the snapshot name in step 1. They are flags for the save step (step 4). They are not part of the name.
   - `--handoff` marks the snapshot as a **structured handoff**. A handoff is a running item or resumable endpoint. Someone promotes it and then deletes it at the end of its arc. An ordinary snapshot is a point-in-time record instead. Use `--handoff` when the session hands off unfinished, resumable work. Do not use it for a routine end-of-session summary.
   - `--expires <UTC-ISO>` sets an explicit expiry (`YYYY-MM-DDTHH:MM:SSZ`). It has meaning only together with `--handoff`. Without it, the expiry is `created + 14 days`. `expires` means "stale, eligible for confirmed cleanup". Nothing deletes a handoff silently.
   - Without `--handoff`, this command writes a plain snapshot. If the snapshot name is **already** a handoff, the command **refuses** and does not change the handoff or drop its metadata. `save-context.sh` exits 2 with the single stderr line `handoff exists: re-run with --handoff`. When this happens, tell the user and re-run with `--handoff`.
   - Regenerating an existing handoff with `--handoff` is a normal **update**. It keeps the original `created` date and advances `updated` to now. It keeps the existing `expires` unless you give `--expires` this time, which replaces it.
   - Regenerating an existing **plain** snapshot with `--handoff` **upgrades** it. Its `created` becomes now, because a plain snapshot carries no prior metadata to preserve.

1. **Determine the snapshot name.** Use `$ARGUMENTS` with the handoff flags removed. If `$ARGUMENTS` has no name, derive one from the Claude session name or the current directory name. Snapshot and handoff names are canonical `snake_case` slugs that match `^[a-z0-9]+(_[a-z0-9]+)*$`. Reject a user-supplied name that does not match. To normalize a derived default, lowercase it, replace each run of non-alphanumeric characters with `_`, and trim leading and trailing underscores.

2. **Gather the session context.** Check these sources:
   - `git diff --stat HEAD` — files currently modified
   - `git log --oneline -10` — recent commits in this session
   - `git diff --name-only HEAD~5..HEAD` — files changed in last 5 commits
   - Any `docs/TODO.md` or `docs/ISSUES.md` — tracked items
   - Any open problems or blockers encountered during the conversation

3. **Generate the summary** with these sections. Include only the sections that apply.

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

   **For every `--handoff` invocation**, also stage a separate JSON data file with `scope` and `items`. Follow the [handoff evidence contract](../knowledge/references/handoffs.md).
   - Use a stable logical repository ID and repository-relative paths.
   - Give each work item a stable ID, a summary, its current session-work status, and an evidence list.
   - Record only observed evidence. `done` requires at least one evidence entry. No evidence is verified automatically.
   - If the session consulted a memory entry for an item, cite it as `reference` evidence. Set `ref` to `memory:<slug>`. The slug is the canonical `snake_case` file stem of the entry, for example `memory:project_widget_firmware`. `/knowledge:doctor` uses this citation to report the lifecycle status of that entry.
   - Never guess or search for a slug to cite. Never cite an entry you did not read. Nothing matches items to memories by name on its own.
   - When you update a handoff, preserve the existing IDs. Mark abandoned items `cancelled` instead of dropping them.
   - This data file makes the saved handoff v2. Supplying it for an existing v1 handoff upgrades its structure and keeps its original creation and expiry metadata.
   - Plain snapshots do not use this data file.

   **Staging ticket citations.** This applies only if `--handoff` was given and the session cites tracking items worth resurfacing at promotion time. A tracking item is a `TODO.md` or `ISSUES.md` entry or an external ticket. Prepend a minimal frontmatter fence to the temp file in step 4, **before** the `# Session Context: <name>` line. The fence contains only a `tickets:` list. Prefix each item with `  - `:
   ```
   ---
   tickets:
     - ext:<ID>
     - local:<tracker-path>:<entry-text prefix>
   ---
   # Session Context: <name>
   ...
   ```
   - `ext:<ID>` cites an external ticket. `<ID>` must match `[A-Z][A-Z0-9]+-[0-9]+`. The ticket is always reported unverifiable and is never fetched.
   - `local:<tracker-path>:<prefix>` cites a repo tracker file (`TODO.md` or `ISSUES.md` at the repo root or under `docs/`). Everything after the *second* colon is the verbatim, non-empty, single-line prefix to look for in that file. Do not add a third colon. Do not split the value differently.
   - This fence is **the only** frontmatter a caller can stage in the Markdown. Scope and items come from the separate JSON file. `save-context.sh` computes the version and timestamps itself and rejects any other staged key.
   - Omit the fence when there is nothing to cite. The fence is never required. When you update a handoff, retain citations that are still relevant.

4. **Save the snapshot.** Write the summary to a temp file, then run the helper. `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. The pane or session launcher sets it. Never export or derive it here. Run exactly one Bash segment. Use no `export` beforehand, no `env` or variable-assignment prefix, and no other command chained, piped, redirected, or substituted around it:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/save-context.sh" "<snapshot-name>" "<temp-file>" [--handoff --handoff-data "<data-json-file>"] [--expires <UTC-ISO>]
   ```
   - Include `--handoff` and `--expires` only if step 0 found them in `$ARGUMENTS`.
   - For a handoff, add `--handoff-data` with the file staged in step 3.
   - For a plain snapshot, omit all three flags.
   - V2 saves require Python 3.
   - Four conditions exit 2 before the destination or its history changes: invalid structured data, a dropped item ID, a changed repository, or an existing handoff of an unknown version.
   - If a snapshot with the same name exists, the helper archives the previous version to `$SESSION_CONTEXT_HOME/.history/`. It keeps the 10 most recent versions. Compare versions later with `/context-diff <snapshot-name>`.

   Handle the result by exit code:

   | Result | Meaning | Next action |
   |---|---|---|
   | Exit `0` | Saved. | Go to step 5. |
   | Script reports `SESSION_CONTEXT_HOME` is not set | The environment lacks the store. | Stop. Ask the user to relaunch this pane or session with the correct environment. Do not derive another context store. |
   | Exit `2`, stderr `handoff exists: re-run with --handoff` | You omitted `--handoff` for a snapshot that is already a handoff. | Tell the user. Re-run step 4 with `--handoff` added. Never add `--handoff` without saying so, because it changes what the helper writes. |
   | Exit `2`, an `ERROR: handoff data:` line | The helper rejected the staged JSON. The message names the field or the retained-ID or repository rule. | Fix the data file as the message describes. Re-run. Never drop an existing item ID to satisfy the check. |
   | Any other non-zero exit (bad `--expires` format, unknown flag, store error) | The helper failed. | Relay the stderr verbatim. Stop. Do not guess a different invocation. |

5. **Report.** Lead with the result. On success, use this form:

   "Session context saved as '<snapshot-name>'. Share with `/context-share <session> <snapshot-name>` or load later with `/context-load <snapshot-name>`."

   - If the helper archived a previous version, add `/context-diff <snapshot-name>` to show what changed.
   - If the snapshot is a handoff, also state its `expires` date. State that `/knowledge:promote` promotes it and then deletes its source. Expiry only marks the handoff stale and eligible for confirmed cleanup. Nothing deletes it silently.
   - If the save did not succeed, report `failed` or `refused`, the stderr line, and the next action from the table in step 4.

Keep the summary to what another session needs to continue the work. Do not write a transcript.
