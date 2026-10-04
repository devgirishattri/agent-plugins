---
description: "A combined docs, memory and context wrap-up selects distill, shows one batch with a manifest hash and writes nothing without approval."
tags: [knowledge, contract]
runs: 1
max_turns: 12
allowed_tools: [Read, Glob, Grep, Bash, Write, Edit, Skill]
expected_outcome: "A combined docs, memory and context wrap-up selects distill, shows one batch with a manifest hash and writes nothing without approval."
---

Wrap up this session. We decided that release tags use the format vYYYY.MM.DD. Save it everywhere it belongs: the docs, the memory store, and a context snapshot so the next session can continue. No tracker is configured; if a ticket note is warranted, only draft it locally for the synthetic ticket EVAL-1 and do not file anything.
