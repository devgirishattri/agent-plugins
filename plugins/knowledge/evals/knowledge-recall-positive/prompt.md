---
description: A user asks what the team already knows before a release; the knowledge recall/search surface should answer from the local store.
tags: [knowledge, positive, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Skill]
expected_outcome: Claude consults the local knowledge store and cites the release checklist memory by slug.
---

Before I cut a release, what do we already know about our release checklist? Check the project's knowledge store first and cite what you find.
