---
name: context-diff
description: "Diff a saved session context snapshot against its archived history versions for the current Codex project."
---

# Context Diff

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-context/0.6.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

`SESSION_CONTEXT_HOME` is required by the scripts and is exported automatically by the command wrapper to `<git-root>/tmp/contexts` (or pwd when not in a git repo) unless already set.

If no snapshot name is provided, tell the user:

```text
Usage: $session-context:context-diff <snapshot-name> [--versions | <timestamp>]
```

Run:

```bash
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/diff-context.sh" "<snapshot-name>" [--versions | <timestamp>]
```

Modes:
- `<snapshot-name>` only — unified diff of the newest archived version against the current snapshot.
- `--versions` — list available history timestamps (UTC, `YYYYMMDD-HHMMSSZ`).
- `<timestamp>` — diff that archived version against the current snapshot.

Present the unified diff in a fenced code block and summarize the change briefly. If the output says "(no differences)", say the snapshot is unchanged. If no history versions exist, explain that history is only created when `$session-context:context-generate` overwrites an existing snapshot. If the snapshot does not exist, suggest `$session-context:context-list`.
