---
type: tool_used
tool: Bash
input_match: '(?:^|\s|[;&|"]|\\n)(?:>>?|tee(?:\s+-a)?)\s*\\?["\'']?[^\s"\'']*(?:docs/|\.agents/memory/|\.tmp/contexts/|contexts/)|\b(?:mv|rm|touch|ln|truncate|install)\b[^;&|]*?(?:docs/|\.agents/memory/|\.tmp/contexts/|contexts/)|\bsed\s+-[A-Za-z]*i[^;&|]*?(?:docs/|\.agents/memory/|\.tmp/contexts/|contexts/)'
min: 0
max: 0
arm: both
---
