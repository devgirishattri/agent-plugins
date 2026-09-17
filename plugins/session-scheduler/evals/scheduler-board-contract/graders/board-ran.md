---
# These commands run their script through a pre-execution `!` block inside the
# command expansion, not through the Bash tool, so the observable is the Skill
# invocation itself (plus the regex on the relayed output).
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?(task-board|task-status)"'
arm: with-only
---
