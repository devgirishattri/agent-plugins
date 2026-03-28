---
description: Collect results from completed worker tasks
argument-hint: [label | all]
allowed-tools: Bash(bash:*), Read
---

## Results

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/collect-result.sh $ARGUMENTS`

## Instructions

Present each task result clearly:
- Show the task label as a heading
- Show the worker's response text
- If no completed tasks, report that and suggest checking `/dispatch-status`
