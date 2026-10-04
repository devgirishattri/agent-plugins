---
name: context-verify
description: Verify a v2 handoff's recorded local evidence against a bound repository — read-only fixed Git queries only, never runs recorded commands, never fetches.
when_to_use: User asks to verify, check, or validate a handoff's evidence, freshness, paths, or commits before trusting it ("is this handoff still valid", "verify the handoff against the repo").
argument-hint: "<snapshot-name> --repository-id <snake_case> [--repo <path>] [--json]"
allowed-tools: Bash(bash:*)
---

## Instructions

`verify-context.sh` is read-only. It never writes to the context store or the repository. It runs only fixed read-only Git queries (object type, `HEAD`, ancestry, shallow state). It never executes a recorded `test` command. It never fetches anything.

Run exactly one literal Bash segment. Use no `export`, `env`, or assignment prefix. Do not chain, pipe, or redirect:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/verify-context.sh" "<snapshot-name>" --repository-id <snake_case> [--repo <path>] [--json]
```

Build the arguments from `$ARGUMENTS`:
- `<snapshot-name>` is required. It must be a canonical `snake_case` name (`^[a-z0-9]+(_[a-z0-9]+)*$`). Reject anything else.
- `--repository-id <snake_case>` is required. It is the caller's explicit assertion of which logical repository the handoff belongs to. The script compares it to the saved `scope.repository` of the handoff and refuses on a mismatch. If the user did not supply it, ask the user. Never derive it from the directory name or a remote URL.
- `--repo <path>` is optional. It names the repository to verify against. Omit it to use the current working directory. The script resolves either one to its Git toplevel, and the report names that toplevel.
- Add `--json` only if the user wants the raw report object.
- `SESSION_CONTEXT_HOME` must already be present in this session's environment, inherited when the agent process started. If the script reports that it is not set, stop. Ask the user to relaunch this pane or session with the correct environment. Do not export the variable. Do not derive another context store.

## What is and is not verified

The script makes only the narrow local checks below, per the [handoff evidence contract](../knowledge/references/handoffs.md).

| Evidence | Check | Result |
|---|---|---|
| `scope.paths` and `file` | The path exists under the repository toplevel and is a regular file. For scope paths, a directory also counts. | `verified` if the check passes. |
| `scope.paths` and `file` with a symlink anywhere on the path | The script never follows the symlink. It never reads contents. | `unverified` |
| `commit` | The object exists locally, is a commit, and is an ancestor of `HEAD`. | `verified` if all three hold. |
| `commit` that is not a commit object | The object type is wrong. | `mismatch` |
| `commit` that exists but is not in `HEAD` history, when that history is complete | The ancestry check fails. | `mismatch` |
| `commit` in a shallow clone | A commit that is present and reachable is still `verified`. Only what the truncated history cannot establish is `unverified`. | `verified` or `unverified` |
| `commit` with an unborn `HEAD` | The ancestry check cannot run. Path and object-type checks still run. | Decided by the remaining checks |
| `test` and `reference` evidence, and items with no evidence | The script never executes, fetches, or resolves them. | `unverified` |

- This command does not check ticket citations. `/knowledge:doctor` classifies them.
- Nothing this command reports proves that an item is complete, current, or true. `verified` means that the referenced local object is present and consistent with the repository right now.
- This verifier does not assess freshness. `/knowledge:doctor` reports handoff expiry and the metadata-based freshness and consistency cues (evidence age, timestamp order, open items past expiry).

## Output

The default output has these parts, in order:
1. A header that states that recorded claims are fallible.
2. The notice of limits.
3. A `Repository:` line with the resolved toplevel.
4. A `HEAD:` line with the commit id (or none) and the shallow flag.
5. One line per check: `STATUS <item-id>/<category> "<ref>": <detail>`. The repository-binding and `scope` checks carry no item id.
6. A `Summary:` line with the counts of verified, missing, mismatch, and unverified checks.

`--json` emits one object (`report_version: 1`). The object holds:
- the handoff name
- `repository` (the toplevel), `repository_id`, and `scope_repository`
- `head` and `shallow`
- `items`, each with its `reported_status`
- `checks`, each with `category`, `ref`, `status` (`verified|missing|mismatch|unverified`), `detail`, and `item_id` / `evidence_index` where applicable
- `summary` counts and the `notice`

## Report to the user

Lead with the overall result: all verified, or the count of `MISSING`, `MISMATCH`, and `UNVERIFIED` rows. Use only these status words.

1. Group the rows per item.
2. List the `MISSING` and `MISMATCH` rows first.
3. List the `UNVERIFIED` rows next.
4. End with a one-line count of what the script verified.
5. Quote the repository toplevel and the `HEAD` that the script used. The user can then tell whether the right checkout was bound.

Do not present `unverified` as a defect of the handoff. It is the expected state for `test` and `reference` evidence and for symlinks.

## Exit codes

| Exit | Meaning | Next action |
|---|---|---|
| `0` | Every check passed. Nothing is unverified. | Report `verified`. |
| `1` | At least one check is missing, mismatched, or unverified. | Relay which checks, using the report above. |
| `2` | Input, schema, or environment error. | Relay the stderr line verbatim. Stop. |

Exit `2` has these causes:
- The snapshot is a plain snapshot or a v1 handoff. It has nothing structured to verify. Suggest that the user regenerate it with `/knowledge:context-generate <name> --handoff` so that it carries evidence.
- The `--repository-id` does not match the saved `scope.repository`.
- The handoff fails schema validation.
- The store is unusable or not owned by the user.
- The repository is not a Git work tree.
- `python3` or `git` is unavailable.

$ARGUMENTS
