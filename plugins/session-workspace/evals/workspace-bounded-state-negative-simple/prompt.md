---
description: Running an existing ordering check goes straight to that check and never loads verification-recipe.
tags: [workspace, negative, verification-recipe]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

We already have tests/run.sh for the queue's retry and late-ack ordering. Run it and tell me the result.
