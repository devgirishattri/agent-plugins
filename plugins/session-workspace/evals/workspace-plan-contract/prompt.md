---
description: The dry-run plan must be produced from the fixture config and mutate nothing.
tags: [workspace, contract]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

Dry-run the workspace plan using --config .agent-workspace/workspace.json and show what it would create. Do not start anything.
