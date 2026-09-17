---
description: Deleting an ordinary file must never route to session deletion.
tags: [manager, negative]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
---

Delete the file scratch.txt in this workspace.
