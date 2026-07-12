---
name: context-list
description: "List available session context snapshots for the current Codex project."
---

# Context List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve `PLUGIN_ROOT` from this selected skill's absolute source path by going up two directories from `<plugin-root>/skills/context-list/SKILL.md`. Never derive it from the project working directory or embed a cache version.

`SESSION_CONTEXT_HOME` is required by the scripts and is exported automatically by the command wrapper to `<git-root>/tmp/contexts` (or `<pwd>/tmp/contexts` when not in a git repo) unless already set.

Run:

```bash
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/list-contexts.sh"
```

Present tab-separated output as:

```text
| Snapshot | Lines | Last Updated | Versions |
```

The Versions column counts archived history entries (created each time a snapshot is overwritten, max 10 kept).

If no snapshots are found, suggest `$session-context:context-generate`. If snapshots are listed, use the first-column snapshot names in suggestions and mention `$session-context:context-load <snapshot-name>`, `$session-context:context-diff <snapshot-name>`, `$session-context:context-share <session> <snapshot-name>`, and `$session-context:context-remove <snapshot-name>`.
