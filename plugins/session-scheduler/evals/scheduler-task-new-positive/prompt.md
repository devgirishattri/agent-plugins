---
description: A request to create a scheduler task routes to the task skill; with no inherited scheduler home the skill must report the fail-closed error, never invent a task id.
tags: [scheduler, positive]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

Create a scheduler task titled "rotate logs" for the ops executor.
