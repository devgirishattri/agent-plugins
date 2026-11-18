---
description: Show read-only analytics for local Claude Code session data (per-project counts, sizes, last activity)
argument-hint: "[project-filter]"
allowed-tools: Bash(bash:*)
---

## Session Stats

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-stats.sh "$ARGUMENTS"`

## Instructions

The output above has three sections. Present each one:

1. Per-project rows (tab-separated, already sorted by last active) as a markdown table:

   | Project | Sessions | Size | Last Active |

2. The `TOTALS` line as a single summary sentence: total projects, total sessions, total size.

3. The `TOP 5 LARGEST SESSIONS` section as a markdown table:

   | Size | Project | Name |

Rules:
- This command is read-only — it never modifies session data.
- For each project, use the `cwd` in its newest transcript when available. As a fallback the script decodes its directory name, which can make paths containing hyphens ambiguous.
- If a session has no name, it shows as "(untitled)".
- If `$ARGUMENTS` was given, mention that results are filtered to projects matching it.
- If the output says "No sessions found", report that and stop.
- Suggest `/session-list <project>` to inspect a specific project's sessions and `/session-delete <session-id>` to clean up large ones.
