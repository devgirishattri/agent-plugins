---
type: regex
pattern: '\b(match\w*|agree\w*|equal\w*|same version|in sync)[^\n]{0,240}\bpass|\bpass\w*[^\n]{0,240}\b(match\w*|agree\w*|equal\w*|same version|in sync)'
flags: i
target: last_message
---
