---
description: "[DEPRECATED — superseded by knowledge] Search context snapshot contents across local projects"
argument-hint: <pattern> [--list]
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: $session-context:context-search <pattern> [--list]`.
2. Resolve the absolute plugin root from the installed plugin source containing
   this command reference and substitute it literally for `<PLUGIN_ROOT>` below.
   Never infer it from the working directory or hardcode a marketplace cache
   version.

3. `SESSION_CONTEXT_HOME` must already be present in this pane's environment,
   inherited when the agent process started (the pane/session launcher sets it —
   never export or derive it here). Invoke the helper as one literal Bash
   segment, with no `export` beforehand, no `env` or variable-assignment prefix,
   and no other command chained, piped, redirected, or substituted around it.
   Pass `--list` through if the user asked for names only:

   ```bash
   bash "<PLUGIN_ROOT>/scripts/search-contexts.sh" "<pattern>" [--list]
   ```

   If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
   pane relaunch with the correct environment instead of deriving another
   context store. Search still requires the inherited variable: it overrides
   only the current repository's store while other discoverable project roots
   use their own stores.

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
- This command does not modify snapshot contents. Resolving a configured store
  may create its directory or harden existing owner-only permissions.
- The current git toplevel is always included and uses the inherited
  `SESSION_CONTEXT_HOME`; additional roots come from `cwd` values recorded in
  local Codex session files and use their own `.tmp/contexts/` stores, falling
  back to legacy `tmp/contexts/` stores. Roots that no longer exist or have no
  discoverable store are skipped, so coverage of other projects is best-effort.
- If no matches were found, report that and suggest `$session-context:context-list` to see snapshots for the current project.
- To load a cross-project match, the pane must have inherited the matching
  project's absolute context-store path as `SESSION_CONTEXT_HOME`. Merely
  changing directories does not switch stores; relaunch the pane through that
  project's launcher with the correct environment, then use
  `$session-context:context-load <snapshot>`.
