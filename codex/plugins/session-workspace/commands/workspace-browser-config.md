---
description: Render or apply browser MCP configuration for Codex and Claude
argument-hint: "[--config PATH] [--provider codex|claude|all] [--apply] [--json]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.
2. Run `bash "$PLUGIN_ROOT/scripts/workspace-browser-config.sh" $ARGUMENTS`.
3. Without `--apply`, report the read-only preview. With `--apply`, report the
   backed-up project-file updates. Relay any unmanaged-entry conflict; never
   overwrite it outside the helper.
