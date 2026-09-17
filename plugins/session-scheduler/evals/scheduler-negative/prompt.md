---
description: A shell one-liner request must not create scheduler tasks.
tags: [scheduler, negative]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

Write a bash one-liner that deletes log files under ./logs older than 7 days. Just show the command.
