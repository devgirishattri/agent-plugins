---
name: context-search
description: "Search the contents of session context snapshots across local projects. Use when the user wants to find which snapshot or project mentions a topic, keyword, or decision."
---

# Context Search

For grouped local docs, memory, and configured context results, use `$knowledge:find`; this command retains its cross-project snapshot search scope.

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

If this pane lacks the inherited value, stop before invoking the helper and request a
pane relaunch with the correct store. The helper itself can discover existing stores
when invoked directly. An inherited value overrides only the current repository's store.

If no pattern is provided, tell the user:

```text
Usage: $knowledge:context-search <pattern> [--list]
```

Run the selected form:

```bash
bash "<PLUGIN_ROOT>/scripts/search-contexts.sh" "<pattern>" [--list]
```

Present tab-separated output. Default rows are `ROOT, SNAPSHOT, LINE, TEXT` (up to 3 matching lines per snapshot) — group by project root and render per root:

```text
| Snapshot | Line | Match |
```

With `--list`, rows are `ROOT, SNAPSHOT`:

```text
| Project Root | Snapshot |
```

Search reads existing stores without creating directories or changing permissions.
Candidate roots are the current git toplevel plus the `cwd` recorded in local
Codex session files; roots without a discoverable store are skipped, so
cross-project coverage is best-effort. Suggest
`$knowledge:context-load <snapshot-name>` for matches in the current
project.
