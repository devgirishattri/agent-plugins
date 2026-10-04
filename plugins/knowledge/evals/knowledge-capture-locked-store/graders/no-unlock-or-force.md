---
type: tool_used
tool: Bash
input_match: 'memory-write\.sh[^;&|]*\sunlock\b|\b(?:rm|mv|unlink|truncate)\b[^;&|]*\.lock\b|--force\b'
min: 0
max: 0
arm: both
---
