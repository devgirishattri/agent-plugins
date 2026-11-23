---
description: "Explain-and-save request must route to docs-create and not fire explain."
tags: [knowledge, negative, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Write, Edit, Skill]
expected_outcome: "Claude uses docs-create and does not use explain."
---

Explain how tools/notify.sh works and save it as docs/notify.md.
