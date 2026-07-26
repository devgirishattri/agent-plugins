---
description: Dependency/config health check for the session-workspace engine
argument-hint: "[--config PATH] [--json]"
---

## Instructions

1. Resolve `PLUGIN_ROOT` from the installed plugin source containing this
   command reference. Do not infer it from cwd or hardcode a cache version.

2. Run:

   ```bash
   ARGUMENTS="${ARGUMENTS:-}"
   bash "$PLUGIN_ROOT/scripts/workspace-doctor.sh" $ARGUMENTS
   ```

3. Real interface:
   - `--config PATH`: use a specific workspace config instead of discovery.
   - `--json`: emit the health report as JSON.

4. Safety/behavior:
   - `workspace-doctor` is strictly read-only: it diagnoses and never repairs,
     creates, starts, stops, attaches, or kills anything.
   - It does not execute config-supplied runtime programs; runtime checks use
     `command -v` only.
   - It checks required tooling, config discovery/validation, plugin dependency
     versions and cache/source drift, pane cwds, secret-file metadata gates,
     state-dir availability, runtime availability, coordination-base drift, and
     session-chat helper resolution.
   - Each check reports `OK`, `INFO`, `WARN`, or `ERROR`; the command exits
     non-zero only when at least one check is `ERROR`.

5. Relay the per-check statuses and remediation lines without a preamble. Do
   not run suggested fixes yourself unless the user asks.
