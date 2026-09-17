---
type: regex
pattern: '\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}|(20\d{2}).{0,40}(UTC|GMT|IST|[+-]\d{2}:\d{2})|(UTC|GMT|IST|[+-]\d{2}:\d{2}).{0,40}(20\d{2})'
flags: i
target: last_message
---
