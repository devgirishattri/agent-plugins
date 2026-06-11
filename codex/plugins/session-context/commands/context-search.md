---
description: Search context snapshot contents across local projects
argument-hint: <pattern> [--list]
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: /context-search <pattern> [--list]`.
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.3.1}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
   ```

3. Run (pass `--list` through if the user asked for names only):

   ```bash
   bash "$PLUGIN_ROOT/scripts/search-contexts.sh" $ARGUMENTS
   ```

4. Present the tab-separated output:

   - Default mode rows are `ROOT, SNAPSHOT, LINE, TEXT` (up to 3 matching lines per snapshot). Group rows by project root, then render a table per root:

     ```text
     | Snapshot | Line | Match |
     ```

   - With `--list`, rows are `ROOT, SNAPSHOT` — render one table:

     ```text
     | Project Root | Snapshot |
     ```

Rules:
- This command is read-only.
- The script searches `tmp/contexts/*.md` in candidate project roots: the current git toplevel (always included) plus the `cwd` recorded in local Codex session files. Roots that no longer exist or have no `tmp/contexts/` are skipped, so coverage of other projects is best-effort.
- If no matches were found, report that and suggest `/context-list` to see snapshots for the current project.
- Suggest `/context-load <snapshot>` to load a matching snapshot (only works when run from inside that snapshot's project).
