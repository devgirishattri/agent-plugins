---
description: "A narrow docs-only wrap-up request selects distill, presents one batch with a manifest hash and stops before any write."
tags: [knowledge, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Write, Edit, Skill]
expected_outcome: "A narrow docs-only wrap-up request selects distill, presents one batch with a manifest hash and stops before any write."
---

Wrap up: save what we decided to the docs. The decision for this session: release tags use the format vYYYY.MM.DD and are cut only from main.
