---
description: Show the task ledger (default active; --all/--pending/--mine/--by-stage or single id)
argument-hint: [<id>|--all|--pending|--mine|--by-stage]
allowed-tools: Bash(bash:*)
---

## Tasks

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/task-status.sh $ARGUMENTS`

## Instructions

If the output starts with a JSON object (single task), pretty-print it as-is, then relay the trailing `Flags:` line (OVERDUE/STALE) and `Dependencies:` list (dep id + status) if present.

For `--by-stage`, relay the grouped output as-is (one `Stage: <name>` block per stage, `(none)` for unstaged tasks).

Otherwise render the tab-separated rows above as a markdown table:

| ID | Status | Stage | Assigner | Assignee | Name | Updated | Flags |

- Flags: `OVERDUE` = past `eta_at`; `STALE` = assigned/review with no update for `SESSION_SCHEDULER_STALE_MINUTES` (default 30) minutes; `-` = none.
- Default filter shows active tasks (`created`, `assigned`, `review`).
- Append the count line at the bottom.
- Suggest `/task-status <id>` for full detail and `/task-board` for the stage-grouped dashboard.
