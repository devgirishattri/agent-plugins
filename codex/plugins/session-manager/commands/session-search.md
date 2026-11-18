---
description: Search Codex sessions by name, ID prefix, or project path
argument-hint: "<search-query> [--archived|--archived-only]"
---

## Instructions

1. If `$ARGUMENTS` is empty, report `Usage: $session-manager:session-search <query> [--archived|--archived-only]`.
2. Resolve `PLUGIN_ROOT` from this command resource's absolute path: it is the parent directory of `commands/`. Never hard-code a marketplace cache version.

3. The standalone helper accepts one optional state argument after the query. `--archived` includes active and archived records. `--archived-only` searches archived records only. In strict-v1 enforce mode, the orchestrator can pass exactly one literal query and no archive flag.

   ```bash
   bash "$PLUGIN_ROOT/scripts/search-sessions.sh" "<query>"
   ```

4. Present matching sessions as a markdown table:

   ```text
   | Thread | Session ID | Project | Size | Last Modified |
   ```

Rules:
- Show full Session IDs so users can copy them for `$session-manager:session-delete`.
- If no sessions match, tell the user no sessions matched `$ARGUMENTS`.
- Show the count of matching sessions at the bottom.
- Mention that `$session-manager:session-delete <session-id>` can be used to delete a session.
