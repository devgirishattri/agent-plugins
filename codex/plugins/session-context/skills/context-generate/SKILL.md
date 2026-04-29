---
name: context-generate
description: "Generate a concise context snapshot for the current Codex session or project so another session can continue the work."
---

# Context Generate

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.1.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

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
bash "$PLUGIN_ROOT/scripts/save-context.sh" "<snapshot-name>" "<temp-file>"
```
