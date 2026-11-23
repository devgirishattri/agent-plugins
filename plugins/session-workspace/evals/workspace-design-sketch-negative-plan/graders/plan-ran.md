---
# workspace-plan runs its script through a pre-execution `!` block, so the
# observable is the Skill invocation itself.
type: tool_used
tool: Skill
input_match: '"skill"\s*:\s*"(?:[\w-]+:)?workspace-plan"'
arm: with-only
---
