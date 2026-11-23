---
type: regex
pattern: '\b(three|3)\b[^.\n]{0,40}(attempt|tr(y|ies)|times|retr)|(attempt|retr\w*)[^.\n]{0,40}\b(three|3)\b'
flags: i
target: last_message
---
