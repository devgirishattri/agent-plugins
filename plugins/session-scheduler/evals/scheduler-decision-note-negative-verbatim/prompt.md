---
description: A caller-supplied note must be passed verbatim to task-review.sh, not expanded into a decision note.
tags: [scheduler, negative]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

Move task t7 to review with exactly this note: abc1234
