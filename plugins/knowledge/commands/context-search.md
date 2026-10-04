---
description: Search context snapshot contents across local projects
argument-hint: <pattern> [--list]
allowed-tools: Bash(bash:*)
---

## Context Search Results

Searching snapshot contents for: **$ARGUMENTS**

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/search-contexts.sh" $ARGUMENTS`

## Instructions

This command uses `SESSION_CONTEXT_HOME` only as an override for the **current** project's store. The cross-project scan does not need it. The value must come from the environment inherited when the agent process started. Never export or derive it here.

The script searches the contents of `.tmp/contexts/*.md` snapshots across local projects. For each project, it falls back to the legacy `tmp/contexts/`. Candidate project roots come from two sources: the current git toplevel (always included), and paths decoded from `~/.claude/projects/*` directory names.

Path decoding is best-effort. A directory name that contains hyphens can decode to a path that does not exist (for example a project at `/Users/foo/ProjectA-app`). The script silently skips that project, unless it is the current project.

Present the tab-separated output:

- Default mode rows are `ROOT, SNAPSHOT, LINE, TEXT` (up to 3 matching lines per snapshot). Group rows by project root. Render a table for each root:

  | Snapshot | Line | Match |

- With `--list`, rows are `ROOT, SNAPSHOT`. Render one table:

  | Project Root | Snapshot |

Rules:
- This command is read-only. It sweeps snapshot contents across other local projects. To search the docs, memory, and context of the current repository together, use `/knowledge:find`.
- If `$ARGUMENTS` is empty, tell the user: Usage: `/context-search <pattern> [--list]`
- If the script finds no matches, report that and suggest `/context-list` to see the snapshots of the current project.
- To load a cross-project match, the pane must have inherited that project's absolute context-store path as `SESSION_CONTEXT_HOME`, because merely changing directories does not switch stores. Relaunch the pane through that project's launcher with the correct environment. Then run `/context-load <snapshot>`.
