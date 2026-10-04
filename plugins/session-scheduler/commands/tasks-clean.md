---
description: Delete old tasks and every artifact they own (prompt, packets, handoffs) past a threshold in days — any status by default, narrow with --status; keeps prerequisites still referenced by surviving tasks; also sweeps aged orphans (dry-run by default; --apply to actually delete)
argument-hint: "[--older-than DAYS] [--status STATUS] [--apply]"
allowed-tools: Bash(bash:*)
---

## Instructions

Lead with the result. Add text only for errors or the follow-ups below. This command is destructive. Deletion needs an explicit user confirmation. The default is a dry-run with `--older-than 7`. The unit is **days**. A bare integer is days on both providers.

The command always retains tasks with a verification contract (see the `task-contract` skill), whatever their age or status.

One task's cleanup removes these items by exact name, never an `<id>-*` glob: `tasks/<id>.json`, `prompts/<id>.md`, `prompts/<id>-review.md`, `prompts/<id>-ack-{done,blocked,review}.md`, the whole `handoffs/<id>/` directory, and a leftover `locks/<id>.lock/`.

The command keeps a candidate that a task *not* being deleted still lists in `depends_on`. It reports that candidate as `kept <id> (referenced by …)`.

The same run also lists **orphans** under an `Orphans:` heading. Orphans are handoff dirs and known-suffix prompt files whose task JSON is gone and whose mtime is past the threshold. `--apply` deletes orphans too.

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. The pane/session launcher sets it. Never export or derive it here.

Run every invocation below as exactly one Bash segment. Use no `export` beforehand and no `env` or variable-assignment prefix. Chain, pipe, redirect, or substitute no other command around it. If the script reports that the variable is not set, stop. Ask the user to relaunch this pane/session with the correct environment. Do not derive another ledger.

1. **Always run the dry-run FIRST**, even when the user passed `--apply`. Run the script with `--apply` stripped from `$ARGUMENTS`:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/tasks-clean.sh" <ARGUMENTS without --apply>
   ```
   Relay the dry-run output. The user must see the exact task files that deletion would remove.

2. **If the dry-run lists zero candidates**, report that nothing matches and stop. Do not prompt.

3. **If (and only if) `--apply` was in `$ARGUMENTS`** and there is at least one candidate, use **AskUserQuestion** to confirm. Offer the options **"No, cancel" (default)** and **"Yes, delete"**. State how many tasks (with their prompt, packet, and handoff files) and how many orphans the command will delete permanently.
   - On **No/cancel** (or any non-Yes answer): report that deletion was cancelled. Do not run with `--apply`.
   - On **Yes**: re-run with `--apply` appended:
     ```
     bash "${CLAUDE_PLUGIN_ROOT}/scripts/tasks-clean.sh" <ARGUMENTS with --apply>
     ```
     Then relay the result.

4. If `--apply` was NOT passed, the run is a plain preview. After the dry-run, tell the user to re-run with `--apply` to delete. That run still asks for confirmation. Never add `--apply` yourself.
