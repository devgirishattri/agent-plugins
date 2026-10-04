---
description: List context snapshots for the current project
allowed-tools: Bash(bash:*)
---

## Context Snapshots (Current Project)

!`bash "${CLAUDE_PLUGIN_ROOT}/scripts/list-contexts.sh"`

## Instructions

`SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. If the output above reports that it is not set, stop. Ask the user to relaunch this pane or session with the correct environment. Do not export the variable. Do not derive another context store.

Present the tab-separated data above as a markdown table:

| Snapshot | Lines | Last Updated | Versions |

- The Versions column counts archived history entries. The script creates one each time a snapshot is overwritten and keeps at most 10.
- **Handoff rows:** a structured handoff is a snapshot created with `/knowledge:context-generate ... --handoff`. Its row carries exactly two extra tab-separated fields after Versions: `handoff` and its `expires` timestamp (UTC ISO `YYYY-MM-DDTHH:MM:SSZ`).
  - Render them as two additional table columns, **Kind** and **Expires**.
  - Add these columns only if at least one row in this run's output has them.
  - Plain-only output keeps the original four-column table unchanged.
  - A blank or missing Kind means the row is a plain snapshot.
- An `expires` date in the past means the handoff is **stale and eligible for confirmed cleanup** through `/knowledge:promote` (promote, then delete). Nothing deletes it automatically. Point this out for every row whose Expires date has passed.

Then suggest the next action:
- No snapshots found: suggest `/context-generate` to create one.
- Load a snapshot: `/context-load <snapshot>`.
- Compare a snapshot with its previous version: `/context-diff <snapshot>`.
- Share with another session: `/context-share <session> <snapshot>`.
- Delete a snapshot: `/context-remove <snapshot>`.
- A handoff row that is ready to promote (its source is deleted separately): `/knowledge:promote <snapshot>`.
