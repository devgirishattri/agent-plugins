---
name: context-search
description: "Search the contents of session context snapshots across local projects. Use when the user wants to find which snapshot or project mentions a topic, keyword, or decision."
---

# Context Search

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
store. Search still requires the inherited variable: it overrides only the
current repository's store while other discoverable project roots use their own
stores.

If no pattern is provided, tell the user:

```text
Usage: $session-context:context-search <pattern> [--list]
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

The search does not modify snapshot contents, although resolving a configured
store may create its directory or harden existing owner-only permissions.
Candidate roots are the current git toplevel plus the `cwd` recorded in local
Codex session files; roots without a discoverable store are skipped, so
cross-project coverage is best-effort. Suggest
`$session-context:context-load <snapshot-name>` for matches in the current
project.
