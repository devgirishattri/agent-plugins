---
description: Collect results from completed dispatched tasks
argument-hint: [session-name | all]
allowed-tools: Bash(bash:*), Read
---

## Results

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/collect-result.sh $ARGUMENTS`

## Instructions

Present each result clearly:
- Show the session name as a heading
- Show the response text
- If no completed tasks, report that and suggest checking `/dispatch-status`
