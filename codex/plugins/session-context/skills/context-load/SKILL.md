---
name: context-load
description: "Load a previously saved session context snapshot into the current Codex session."
---

# Context Load

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-plugins/session-context/0.6.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

`SESSION_CONTEXT_HOME` is required by the scripts and is exported automatically by the command wrapper to `<git-root>/tmp/contexts` (or pwd when not in a git repo) unless already set.

If no snapshot name is provided, tell the user:

```text
Usage: $session-context:context-load <snapshot-name>
```

Run:

```bash
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/load-context.sh" "<snapshot-name>"
```

Internalize the loaded context, especially what was done, files changed, decisions, open issues, and where the prior session left off. Summarize what was loaded. If a staleness WARNING appears at the end of the output (snapshot older than 7 days, configurable via `SESSION_CONTEXT_STALE_DAYS`), surface it and suggest regenerating with `$session-context:context-generate`. If no snapshot is found, suggest `$session-context:context-list`.
