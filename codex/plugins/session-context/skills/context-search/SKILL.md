---
name: context-search
description: "Search the contents of session context snapshots across local projects. Use when the user wants to find which snapshot or project mentions a topic, keyword, or decision."
---

# Context Search

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the plugin root:

```bash
PLUGIN_ROOT="${CODEX_PLUGIN_ROOT:-$HOME/.codex/plugins/cache/girishattri-codex-plugins/session-context/0.3.0}"
[ -d "$PLUGIN_ROOT" ] || PLUGIN_ROOT="codex/plugins/session-context"
```

If no pattern is provided, tell the user:

```text
Usage: $session-context:context-search <pattern> [--list]
```

Run one of:

```bash
bash "$PLUGIN_ROOT/scripts/search-contexts.sh" "<pattern>"
bash "$PLUGIN_ROOT/scripts/search-contexts.sh" "<pattern>" --list
```

Present tab-separated output. Default rows are `ROOT, SNAPSHOT, LINE, TEXT` (up to 3 matching lines per snapshot) — group by project root and render per root:

```text
| Snapshot | Line | Match |
```

With `--list`, rows are `ROOT, SNAPSHOT`:

```text
| Project Root | Snapshot |
```

The search is read-only. Candidate roots are the current git toplevel plus the `cwd` recorded in local Codex session files; roots without `tmp/contexts/` are skipped, so cross-project coverage is best-effort. Suggest `$session-context:context-load <snapshot-name>` for matches in the current project.
