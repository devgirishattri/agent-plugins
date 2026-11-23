---
description: "A single failure with an ordinary fix request must not fire reflect or any writer skill."
tags: [knowledge, negative, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Edit, Write, Skill]
expected_outcome: "Claude sets tools/version.json to 1.4.2 and does not invoke reflect or a writer skill."
---

The release check failed once: `release-check: tools/version.json is 1.4.1 but CHANGELOG.md top entry is 1.4.2`. Set tools/version.json to 1.4.2.
