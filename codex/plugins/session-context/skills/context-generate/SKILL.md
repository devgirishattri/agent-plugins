---
name: context-generate
description: "Generate a concise context snapshot for the current Codex session or project so another session can continue the work."
---

# Context Generate

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.6.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

`SESSION_CONTEXT_HOME` is required by the scripts and is exported automatically by the command wrapper to `<git-root>/tmp/contexts` (or pwd when not in a git repo) unless already set.

Generate a snapshot under 150 lines. Include relevant sections only:

```text
# Session Context: <name>
Generated: YYYY-MM-DD HH:MM
Project: <current directory>

## What Was Done
## Files Changed
## Key Decisions
## Open Issues
## Where I Left Off
## Notes for Next Session
```

Use the provided snapshot name, or derive one from the current directory. Save it with:

```bash
export SESSION_CONTEXT_HOME="${SESSION_CONTEXT_HOME:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/tmp/contexts}"
bash "$PLUGIN_ROOT/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
```

Before writing the snapshot, gather concise context from recent git history and local docs when available:

```bash
git diff --stat HEAD
git log --oneline -10
git diff --name-only HEAD~5..HEAD
```

Saving over an existing snapshot archives the previous version to `tmp/contexts/.history/` automatically (the 10 most recent versions are kept); compare versions with `$session-context:context-diff <snapshot-name>`.

After saving, report the snapshot name and mention `$session-context:context-share <session> <snapshot-name>` and `$session-context:context-load <snapshot-name>`.
