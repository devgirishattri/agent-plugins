---
description: Verify a v2 handoff's recorded local evidence against a bound repository — path and file existence, commit objects and HEAD ancestry (read-only; runs fixed Git queries only, never the recorded commands, never fetches)
argument-hint: "<snapshot-name> --repository-id <snake_case> [--repo <path>] [--json]"
allowed-tools: Bash(bash:*)
---

## Instructions

`verify-context.sh` is read-only: it never writes to the context store or
the repository, runs only fixed read-only Git queries (object type, `HEAD`,
ancestry, shallow state), and never executes a recorded `test` command or
fetches anything. Run exactly one literal Bash segment (no `export`/`env`/
assignment prefix, no chaining, piping, or redirection):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-context.sh" "<snapshot-name>" --repository-id <snake_case> [--repo <path>] [--json]
```

Build the arguments from `$ARGUMENTS`:
- `<snapshot-name>` is required and must be a canonical `snake_case` name
  (`^[a-z0-9]+(_[a-z0-9]+)*$`); reject anything else.
- `--repository-id <snake_case>` is required. It is the caller's explicit
  assertion of which logical repository the handoff belongs to; the script
  compares it to the handoff's saved `scope.repository` and refuses on a
  mismatch. Never derive it from the directory name or a remote URL — ask the
  user if they did not supply it.
- `--repo <path>` optionally names the repository to verify against; omit it
  to use the current working directory. Either is resolved to its Git
  toplevel, which the report names.
- `--json` only if the user wants the raw report object.
- `SESSION_CONTEXT_HOME` must already be present in this session's
  environment, inherited when the agent process started. If the script
  reports it is not set, stop and request that this pane/session be
  relaunched with the correct environment — do not export the variable or
  derive another context store.

## What is and is not verified

Only the narrow local checks below, per the
[handoff evidence contract](../skills/knowledge/references/handoffs.md):
- `scope.paths` and `file` evidence: the path exists under the repository
  toplevel and is a regular file (a directory also counts for scope paths).
  A symlink anywhere on the path is reported `unverified` and never
  followed; contents are never read.
- `commit` evidence: the object exists locally, is a commit, and is an
  ancestor of `HEAD`. An object that is not a commit is a `mismatch`; so is a
  commit that exists but is not in `HEAD`'s history when that history is
  complete. In a shallow clone a commit that is present and reachable is still
  `verified`; only what the truncated history cannot establish is
  `unverified`. An unborn `HEAD` prevents the
  ancestry check only — path and object-type checks still run.
- `test` and `reference` evidence, and items with no evidence, are reported
  `unverified`. They are never executed, fetched, or resolved.
- Ticket citations are not checked here; `/knowledge:doctor` classifies them.
  Nothing this command reports proves an item is complete, current, or true:
  `verified` means "the referenced local object is present and consistent
  with the repository right now". This verifier does not assess freshness;
  `/knowledge:doctor` reports handoff expiry and the metadata-based freshness
  and consistency cues (evidence age, timestamp order, open items past
  expiry).

## Output

Default: a header stating that recorded claims are fallible, the notice of
limits, a `Repository:` line with the resolved toplevel, a `HEAD:` line with
the commit id (or none) and the shallow flag, then one line per check
`STATUS <item-id>/<category> "<ref>": <detail>` (the repository-binding and
`scope` checks carry no item id), and a `Summary:` line with the counts of
verified, missing, mismatch, and unverified checks. `--json` emits one object
(`report_version: 1`) with the handoff name, `repository` (the toplevel),
`repository_id`, `scope_repository`, `head`, `shallow`, `items` with their
`reported_status`, the `checks` (`category`, `ref`, `status` in
`verified|missing|mismatch|unverified`, `detail`, and `item_id` /
`evidence_index` where applicable), `summary` counts, and the `notice`.

Present the result grouped per item: lead with `MISSING` and `MISMATCH`
rows, then the `UNVERIFIED` ones, then a one-line count of what was
verified. Quote the repository toplevel and `HEAD` the script used, so the
user can tell whether the right checkout was bound. Do not present
`unverified` as a defect of the handoff; it is the expected state for
`test`/`reference` evidence and for symlinks.

Exit codes: `0` every check passed and nothing was left unverified; `1` at
least one check is missing, mismatched, or unverified — relay which; `2`
input, schema, or environment error — the snapshot is a plain snapshot or a
v1 handoff (nothing structured to verify; suggest regenerating it with
`/knowledge:context-generate <name> --handoff` so it carries evidence), the
`--repository-id` does not match the saved `scope.repository`, the handoff
fails schema validation, the store is unusable or not owned by the user, the
repository is not a Git work tree, or `python3`/`git` is unavailable —
relay the stderr line verbatim and stop.

$ARGUMENTS
