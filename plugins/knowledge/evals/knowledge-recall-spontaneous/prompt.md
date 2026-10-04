---
description: "Spontaneous recall: the task's decisive project convention lives only in a seeded memory; the agent must use the recall helper, apply the convention, and not read memory files directly."
tags: [knowledge, positive, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Skill]
expected_outcome: "Spontaneous recall: the task's decisive project convention lives only in a seeded memory; the agent must use the recall helper, apply the convention, and not read memory files directly."
---

I'm adding a `purge-cache` subcommand to tools/cli.sh. What exit code should it return when someone passes a bad flag, and how should the error message start? Answer in one or two lines.
