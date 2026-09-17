---
description: The deterministic search command must be run and its raw TSV pasted back unchanged.
tags: [knowledge, contract]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Bash, Skill]
expected_outcome: Claude runs the knowledge search command for "release" and pastes the raw tab-separated rows, which include the active checklist slug ranked above the stale notes.
---

Run the knowledge search command for the term `release` and paste its raw output back to me exactly as printed, inside a code block. Do not summarise it.
