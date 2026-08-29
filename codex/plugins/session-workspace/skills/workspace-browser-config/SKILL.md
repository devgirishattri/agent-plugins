---
name: workspace-browser-config
description: "Render or explicitly apply project-scoped Codex and Claude MCP entries for a configured session-workspace browser."
---

# workspace-browser-config

Resolve `PLUGIN_ROOT` from this selected skill's installed source path: it is
the directory two levels above this `SKILL.md`. Never infer it from cwd or
hardcode a marketplace-cache version.

Run:

```bash
bash "$PLUGIN_ROOT/scripts/workspace-browser-config.sh" $ARGUMENTS
```

Flags: `--config PATH`, `--provider codex|claude|all`, `--apply`, and
`--json`. Without `--apply` the command is read-only. Apply backs up existing
files and refuses conflicting unmanaged entries; relay that refusal rather
than overwriting the entry.
