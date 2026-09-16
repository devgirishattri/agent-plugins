---
description: Read-only local evidence verification for a structured v2 handoff
argument-hint: "<snapshot-name> --repository-id <id> [--repo <path>] [--json]"
---

# Context Verify

Resolve the absolute plugin root from this installed command's source path:
its parent is `<plugin-root>/commands`, so go up one directory from that parent.
Substitute that path for `<PLUGIN_ROOT>`; never
infer it from the working directory or hardcode a marketplace cache version.

Usage: `$knowledge:context-verify <snapshot-name> --repository-id <id> [--repo <path>] [--json]`.
Both the name and repository ID must be canonical `snake_case`. The repository
ID is the caller's explicit binding to the handoff's `scope.repository`; ask
for it if absent, never infer it from the handoff or a directory name.
`--repo` selects a local Git working tree, defaulting to the current directory;
the verifier resolves its toplevel before checking relative paths. Include
`--json` only when requested. Quote each supplied argument as data.

`SESSION_CONTEXT_HOME` must already be inherited when the agent process started.
If it is missing, relay the error and request a pane relaunch with the correct
environment. Never export it or derive a replacement store.

Run one literal Bash segment, without an assignment prefix, chaining, piping,
redirection, or command substitution:

```bash
bash "<PLUGIN_ROOT>/scripts/verify-context.sh" "<snapshot-name>" --repository-id "<id>" [--repo "<path>"] [--json]
```

The command is read-only. It validates the existing context store without
creating directories, locking, or changing permissions. It accepts v2 handoffs
using the shared schema parser; plain/v1 snapshots require regeneration as v2.

Checks have narrow meanings:

- Scope paths must exist as regular files or directories. File evidence must
  exist as a regular file. Symlinks, including ancestor components, are never
  followed and are unverified. File contents are not read.
- Commit evidence must identify a locally available commit that is an ancestor
  of current `HEAD`. A wrong object type or a non-ancestor in complete history
  is a mismatch. Incomplete shallow history or unavailable `HEAD` can leave
  ancestry unverified. A reachable commit in shallow history can still pass.
- Recorded test/reference evidence and items without evidence remain unverified.
  Recorded commands are never executed, and no references or Git objects are
  fetched. Ticket checking remains the doctor's responsibility.
- Repository identity is a caller assertion. These checks do not prove reported
  item completion, contents, timestamps, freshness, or external ticket state.

Default output includes the repository toplevel, `HEAD`, shallow status,
`STATUS category reference: detail` findings (item IDs prefix evidence
categories), and summary counts. JSON has `report_version: 1`, repository and
handoff details, `items` with reported statuses, ordered `checks`, `summary`,
and a notice describing the limits. Preserve that notice in your interpretation.

Exit `0`: all narrow checks verified with none unresolved. Exit `1`: at least
one `missing`, `mismatch`, or `unverified` finding. Exit `2`: input, schema,
store, dependency, repository-binding, or environment error; relay stderr and
stop. For plain/v1 handoffs, suggest regenerating with
`$knowledge:context-generate <name> --handoff` to supply structured evidence.

Present discrepancies first, then unverified evidence, then the verified count.
Identify the checkout and HEAD used. Do not turn a verified local object into
a claim that its work item is complete. See the
[handoff contract](../skills/knowledge/references/handoffs.md).
