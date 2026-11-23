---
type: regex
pattern: '\b(retr\w+|attempts?|three|\b3\b)(?:(?!weekend|\.\s)[^\n]){0,200}\b(inferred|unknown|no record|not recorded|unrecorded)|\b(inferred|unknown|no record|not recorded|unrecorded)(?:(?!weekend|\.\s)[^\n]){0,100}\b(why|explain\w*|rationale|count)\b(?:(?!weekend|\.\s)[^\n]){0,100}\b(retr\w+|attempts?|three|\b3\b)'
flags: i
target: last_message
---
