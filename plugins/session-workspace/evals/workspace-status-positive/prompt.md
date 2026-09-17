---
description: Asking about the workspace lifecycle state routes to the status skill.
tags: [workspace, positive]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

What is the current state of the tmux workspace lifecycle for this project? Use the workspace config at .agent-workspace/workspace.json.
