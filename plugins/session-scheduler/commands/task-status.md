---
description: Show the task ledger (default active; --all/--pending/--mine/--by-stage/--by-workflow/--workflow or single id)
argument-hint: "[<id>|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]"
allowed-tools: Bash(bash:*)
---

## Tasks

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-status.sh" $ARGUMENTS`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment. It is inherited when the agent process started. If the output above reports that it is not set, stop. Ask the user to relaunch this pane/session with the correct environment. Do not export the variable or derive another ledger.

Contracted tasks show `CONTRACT:<state>` (admitted, closed-unadmitted, active, invalid) in the flags column; a bare `done` is not acceptance.

If the output starts with a JSON object (single task), pretty-print it as-is. Then relay the trailing `Flags:` line (OVERDUE/STALE) and the `Dependencies:` list (dependency id and status), if present.

For `--by-stage`, relay the grouped output as-is. It has one `Stage: <name>` block per stage and `(none)` for unstaged tasks.

For `--by-workflow`, relay the grouped output as-is. It has one `Workflow: <id>` block per workflow. Tasks with no `workflow_id` are omitted.

Otherwise render the tab-separated rows above as a markdown table:

| ID | Status | Stage | Assigner | Assignee | Name | Updated | Flags |

- Flags: `OVERDUE` = past `eta_at`. `STALE` = assigned or review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes. `-` = none.
- Default filter shows active tasks (`created`, `assigned`, `review`).
- `--pending` = `created` only (not yet assigned). `--mine` = tasks where the current pane is the assigner, the assignee, **or** the reviewer. The Codex side behaves the same.
- `--workflow ID` shows every task grouped under that workflow id (set via `/task-new --workflow` or `/task-assign --workflow`).
- Append the count line at the bottom.
- Suggest `/task-status <id>` for full detail and `/task-board` for the stage-grouped dashboard.
