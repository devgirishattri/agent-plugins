---
description: "Save-a-handoff request must route to context-generate and not fire catch-up."
tags: [knowledge, negative, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Write, Skill]
expected_outcome: "Claude saves the handoff through context-generate and does not use catch-up."
---

Save a handoff of where we are as release_prep so another session can pick this up.
