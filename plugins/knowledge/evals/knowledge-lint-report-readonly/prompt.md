---
description: "REPORT: the lint helper must be run read-only and the reported findings must match the fixture store; the destination must stay byte-identical (no --fix). Behavioral outcome unmeasured (stochastic)."
tags: [knowledge, contract, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Write, Edit, Skill]
expected_outcome: "REPORT: the lint helper must be run read-only and the reported findings must match the fixture store; the destination must stay byte-identical (no --fix). Behavioral outcome unmeasured (stochastic)."
---

Run the knowledge plugin's memory lint on this project's store and give me a status report: how many ERROR findings and how many ADVISORY findings it reports, and which memory files they are in.
