---
description: Diff a context snapshot against its archived history versions
argument-hint: <snapshot-name> [--versions | <timestamp>]
---

## Instructions

1. If `$ARGUMENTS` is empty, tell the user: `Usage: /context-diff <snapshot-name> [--versions | <timestamp>]`.
2. Resolve the plugin root:

   ```bash
   PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.6.0}"
   [ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
   ```

3. Run (passing the arguments through):

   ```bash
   export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
   bash "$PLUGIN_ROOT/scripts/diff-context.sh" <snapshot-name> [--versions | <timestamp>]
   ```

   Modes:
   - `<snapshot-name>` only — unified diff of the newest archived version against the current snapshot.
   - `<snapshot-name> --versions` — list available history timestamps (UTC, `YYYYMMDD-HHMMSSZ`).
   - `<snapshot-name> <timestamp>` — diff that archived version against the current snapshot.

4. Show the unified diff in a fenced ```diff code block and briefly summarize what changed.
5. If the output says "(no differences)", state the snapshot is unchanged since that version.
6. If no history versions exist, explain that history is only created when `/context-generate` overwrites an existing snapshot.
7. If the snapshot does not exist, suggest `/context-list`.
