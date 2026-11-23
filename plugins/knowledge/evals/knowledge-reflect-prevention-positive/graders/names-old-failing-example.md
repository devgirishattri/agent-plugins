---
type: regex
pattern: '(1\.4\.1|mismatch\w*|differ\w*|out of sync|stale)[^\n]{0,240}\bfail|\bfail\w*[^\n]{0,240}(1\.4\.1|mismatch\w*|differ\w*|out of sync|stale)'
flags: i
target: last_message
---
