---
name: context-list
description: "List available session context snapshots for the current Codex project."
---

# Context List

When this skill is invoked, do not add a preamble or narrate the plan. Run the relevant script directly, then return only the formatted result or the shortest actionable message.

Resolve the absolute plugin root from this selected skill's installed source
path: it is the directory two levels above this `SKILL.md`. Substitute that
absolute path literally for `<PLUGIN_ROOT>` below; never infer it from the
working directory or hardcode a marketplace cache version.

`SESSION_CONTEXT_HOME` must already be present in this pane's environment,
inherited when the agent process started (the pane/session launcher sets it —
never export or derive it here). Invoke the context helper as one literal Bash
segment, with no `export` beforehand, no `env` or variable-assignment prefix,
and no other command chained, piped, redirected, or substituted around it.

If the script reports `SESSION_CONTEXT_HOME` is not set, stop and request a
pane relaunch with the correct environment instead of deriving another context
store.

Run:

```bash
bash "<PLUGIN_ROOT>/scripts/list-contexts.sh"
```

Present tab-separated output as:

```text
| Snapshot | Lines | Last Updated | Versions |
```

The Versions column counts archived history entries (created each time a snapshot is overwritten, max 10 kept).

A structured handoff row carries exactly two additional fields after Versions: `handoff` and its UTC `expires` timestamp. If at least one row has them, render two additional columns, **Kind** and **Expires**; leave those cells blank for plain snapshots. Plain-only output keeps the original four-column table unchanged.

Treat a past Expires value as stale and eligible for separately confirmed cleanup through `$knowledge:promote`; it is never auto-deleted. Point this out for each expired row.

If no snapshots are found, suggest `$knowledge:context-generate`. If snapshots are listed, use the first-column snapshot names in suggestions and mention `$knowledge:context-load <snapshot-name>`, `$knowledge:context-diff <snapshot-name>`, `$knowledge:context-share <session> <snapshot-name>`, and `$knowledge:context-remove <snapshot-name>`. For a handoff ready to become durable memory or a proposed docs patch, suggest `$knowledge:promote context <snapshot-name>`.
