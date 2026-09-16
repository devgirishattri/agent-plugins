# Structured handoff evidence

A version 2 handoff records the scope of resumable work, stable work-item
identifiers, the session's reported status, and supporting evidence references.
These are fallible recorded claims. Schema validation does not prove a file
exists, a commit belongs to this repository, a test passed, or a ticket is
complete. Evidence references are never fetched or executed.

## Creating and updating a handoff

Stage the Markdown body as usual. Its optional leading frontmatter still
accepts only the existing `tickets:` list. Stage the structured data separately
as a JSON file and pass it to the save helper:

```text
bash <plugin-root>/scripts/save-context.sh example_arc /tmp/body.md --handoff --handoff-data /tmp/data.json
```

`SESSION_CONTEXT_HOME` must already be inherited from the launcher. The new
flag requires `--handoff`; it does not change how the context store is chosen.
Python 3 is required for v2 writes and validation. Plain snapshots and legacy
v1 writes without structured data retain their existing dependency behavior.

The JSON file contains exactly `scope` and `items`:

```json
{
  "scope": {"repository": "project_a", "paths": ["src", "tests"]},
  "items": [{
    "id": "retry_fix",
    "summary": "Repair retry behavior",
    "status": "in_progress",
    "evidence": [{
      "kind": "file",
      "ref": "src/retry.py",
      "observed_at": "2026-09-16T10:00:00Z",
      "note": "Retry branch updated; integration test still pending."
    }]
  }]
}
```

Use the file-editing tool to stage both files. The helper takes a file path,
not an inline JSON argument. It rejects duplicate JSON keys, unknown fields,
and malformed values before replacing the destination or adding history.

## Field contract

| Field | Meaning and accepted values |
|---|---|
| `scope.repository` | Required stable logical repository ID, in `snake_case`. It is not a remote URL or an absolute machine path. Derive it once from the repository name when authoring a new handoff, then preserve it. |
| `scope.paths` | Nonempty list of repository-relative POSIX paths. Use `.` for the whole repository. Absolute paths, backslashes, colons, and `..` components are rejected; paths are not checked for existence. |
| `items` | Nonempty list of work items. IDs must be unique within the handoff. |
| `item.id` | Stable `snake_case` identifier such as `retry_fix`, retained across updates. Do not renumber IDs when reordering items. |
| `item.summary` | Required nonempty single-line description of the work. |
| `item.status` | `pending`, `in_progress`, `blocked`, `done`, or `cancelled`. This describes session work, not the authoritative state of an external ticket. |
| `item.evidence` | Required list; it may be empty unless status is `done`. A done item requires at least one recorded evidence entry, which remains unverified. |
| `evidence.kind` | `file`, `commit`, `test`, or `reference`. |
| `evidence.ref` | File: a relative path under the same path rules as scope. Commit: full lowercase 40- or 64-hex object ID. Test: a command or test identifier stored as text. Reference: a citation stored as text. All must be nonempty and single-line. |
| `evidence.observed_at` | Required valid UTC calendar timestamp, exactly `YYYY-MM-DDTHH:MM:SSZ`, recording when the supporting observation was made. |
| `evidence.note` | Optional nonempty single-line observation, such as the recorded test result. |

Text fields must be YAML-printable; control characters, unpaired surrogates,
and Unicode line separators are rejected. Record only
observations actually available to the session; leave evidence empty for
unfinished work rather than manufacturing a result or timestamp.

## Compatibility and stable updates

- New `--handoff --handoff-data` writes produce `handoff_version: 2`.
- An existing v1 handoff can be upgraded by supplying data; its original
  `created` and existing `expires` are preserved, unless `--expires` replaces
  the latter. `updated` advances as before.
- An existing v2 handoff updated without `--handoff-data` keeps its scope and
  item values. Their JSON formatting is canonicalized.
- With replacement data, all previous item IDs must still be present. Mark an
  abandoned item `cancelled` instead of omitting it. Summary, status, evidence,
  and scoped paths can change; repository identity cannot. Use another handoff
  name for a different repository.
- Legacy direct helper calls without data still create v1 handoffs. Existing
  plain snapshots and v1 handoffs remain readable; there is no bulk migration.
- A plain save against an existing handoff still refuses. Unknown existing
  handoff versions and malformed v2 data also refuse before archival or overwrite.
- The existing history limit, timestamp handling, expiry policy, and top-level
  ticket-citation scheme continue to apply. Expiry never deletes anything.

The work-item IDs belong to a handoff; they do not create or update tracker
entries. Top-level `tickets:` continues to hold tracker pointers separately.
When regenerating a handoff, retain the ticket references still needed by the
next session.

## Stored representation and diagnosis

`save-context.sh` remains the writer of the complete handoff. It emits its
timestamps and optional tickets first, then `scope: {JSON object}`, then
`items:` with one `  - {JSON object}` line per item, before the closing
frontmatter fence and Markdown body. This is a restricted, valid YAML format;
it does not require a general YAML parser. Object keys are sorted, Unicode is
preserved, and each structured value stays on one physical line.

`handoff-data.py` supplies shared structural validation and rendering.
`doctor.sh` accepts both handoff versions, reports malformed v2 data as a WARN,
and labels recorded item evidence as not verified. Its existing timestamp,
expiry, and ticket checks still run. It does not compare IDs against history
or assess evidence freshness or truth.

## Verifying recorded evidence

`context-verify <name> --repository-id <snake_case> [--repo <path>] [--json]`
(`verify-context.sh` → `context-verify.py`, which imports the shared parser)
performs local checks of the structured evidence, and it is deliberately
narrow, local, and read-only. It runs fixed Git queries (object type, `HEAD`,
ancestry, shallow state) and never a recorded command; it never fetches:

- The caller binds the repository explicitly. `--repository-id` is compared to
  the saved `scope.repository` and a mismatch is an input error (exit 2); it
  is never derived from a directory name or remote URL. `--repo` (default:
  the current git toplevel) is resolved to its toplevel, which the report
  names.
- `scope.paths` and `file` evidence: exists under the toplevel and is a
  regular file (a directory is acceptable for scope paths). A symlink on the
  path is reported `unverified` and is never followed; contents are never
  read.
- `commit` evidence: the object exists locally, is a commit, and is an
  ancestor of `HEAD`. Present-but-not-ancestor and wrong-object-type are
  mismatches. In a shallow clone a present, reachable commit is still
  `verified`; only what the truncated history cannot establish is
  `unverified`. An unborn `HEAD` prevents the ancestry check only; path and
  object-type checks still run.
- `test` and `reference` evidence, and items with no evidence, are reported
  `unverified`; nothing is executed, fetched, or resolved.
- Ticket citations are doctor's concern. This verifier does not assess
  freshness or completion (doctor reports handoff expiry).

Exit `0` means every local check passed and nothing was left unverified;
`1` means at least one check is missing, mismatched, or unverified; `2` is an
input, schema, or environment error (including a plain snapshot or a v1
handoff, which carry no structured evidence — regenerate with `--handoff` to
get a v2). The JSON report (`report_version: 1`) lists every check with its
category, reference, status (`verified|missing|mismatch|unverified`), detail,
and owning item, plus `head`, `shallow`, summary counts, and a notice
restating these limits. The human report prints the notice, the resolved
repository and `HEAD`, one `STATUS <item-id>/<category> "<ref>": <detail>`
line per check (the repository-binding and `scope` checks carry no item id),
and a summary line. The store is opened through the same read-only gate
doctor uses, never through the hardening resolver.

Load, list, share, diff, and remove continue using the existing context
mechanics. Promotion should consider the recorded scope, item statuses, and
evidence as background and preserve relevant provenance in its proposal;
these fields do not authorize a durable write or source deletion.
