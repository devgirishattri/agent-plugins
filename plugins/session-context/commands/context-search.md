---
description: Search context snapshot contents across local projects
argument-hint: <pattern> [--list]
allowed-tools: Bash(bash:*)
---

## Context Search Results

Searching snapshot contents for: **$ARGUMENTS**

!`bash ${CLAUDE_PLUGIN_ROOT}/scripts/search-contexts.sh $ARGUMENTS`

## Instructions

The script searches the contents of `tmp/contexts/*.md` snapshots across local projects. Candidate project roots come from the current git toplevel (always included) plus paths decoded from `~/.claude/projects/*` directory names. Path decoding is best-effort: directory names containing hyphens may decode to non-existent paths (e.g. a project at `/Users/foo/ProjectA-app`), in which case that project is silently skipped unless it is the current project.

Present the tab-separated output:

- Default mode rows are `ROOT, SNAPSHOT, LINE, TEXT` (up to 3 matching lines per snapshot). Group rows by project root, then render a table per root:

  | Snapshot | Line | Match |

- With `--list`, rows are `ROOT, SNAPSHOT` — render one table:

  | Project Root | Snapshot |

Rules:
- This command is read-only.
- If `$ARGUMENTS` is empty, tell the user: Usage: `/context-search <pattern> [--list]`
- If no matches were found, report that and suggest `/context-list` to see snapshots for the current project.
- Suggest `/context-load <snapshot>` to load a matching snapshot (only works when run from inside that snapshot's project).
