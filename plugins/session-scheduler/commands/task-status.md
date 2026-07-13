---
description: Show the task ledger (default active; --all/--pending/--mine/--by-stage/--by-workflow/--workflow or single id)
argument-hint: "[<id>|--all|--pending|--mine|--by-stage|--by-workflow|--workflow ID]"
allowed-tools: Bash(bash:*)
---

## Tasks

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/task-status.sh" $ARGUMENTS`

## Instructions

`SESSION_SCHEDULER_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports it is not set, stop and request that this pane/session be relaunched with the correct environment — do not export the variable or derive another ledger.

If the output starts with a JSON object (single task), pretty-print it as-is, then relay the trailing `Flags:` line (OVERDUE/STALE) and `Dependencies:` list (dep id + status) if present.

For `--by-stage`, relay the grouped output as-is (one `Stage: <name>` block per stage, `(none)` for unstaged tasks).

For `--by-workflow`, relay the grouped output as-is (one `Workflow: <id>` block per workflow; tasks with no `workflow_id` are omitted).

Otherwise render the tab-separated rows above as a markdown table:

| ID | Status | Stage | Assigner | Assignee | Name | Updated | Flags |

- Flags: `OVERDUE` = past `eta_at`; `STALE` = assigned/review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes; `-` = none.
- Default filter shows active tasks (`created`, `assigned`, `review`).
- `--workflow ID` shows every task grouped under that workflow id (set via `/task-new --workflow` or `/task-assign --workflow`).
- Append the count line at the bottom.
- Suggest `/task-status <id>` for full detail and `/task-board` for the stage-grouped dashboard.
