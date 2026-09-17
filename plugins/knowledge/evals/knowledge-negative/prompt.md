---
description: An ordinary editing request must not trigger any knowledge writer skill.
tags: [knowledge, negative, contract]
runs: 1
max_turns: 8
allowed_tools: [Read, Glob, Grep, Skill]
expected_outcome: Claude answers the rename directly and never invokes consolidate, promote, remember, or docs-create.
---

Rename the variable `count` to `total` in this snippet and show me the result:

```python
count = 0
for item in items:
    count += item.size
print(count)
```
