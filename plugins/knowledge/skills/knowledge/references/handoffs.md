# Structured handoff evidence

A version 2 handoff records four things: the scope of resumable work, stable work-item identifiers, the reported status of the session, and supporting evidence references.

These are fallible recorded claims. Schema validation does not prove that a file exists, a commit belongs to this repository, a test passed, or a ticket is complete. Handoff handling never fetches or executes evidence references.

## Creating and updating a handoff

Stage the Markdown body as usual. Its optional leading frontmatter accepts only the existing `tickets:` list. Stage the structured data separately as a JSON file. Pass it to the save helper:

```text
bash <plugin-root>/scripts/save-context.sh example_arc /tmp/body.md --handoff --handoff-data /tmp/data.json
```

`SESSION_CONTEXT_HOME` must already be inherited from the launcher. The new flag requires `--handoff`. It does not change how the helper chooses the context store.

V2 writes and validation require Python 3. Plain snapshots and legacy v1 writes without structured data keep their existing dependency behavior.

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

Use the file-editing tool to stage both files. The helper takes a file path. It does not take an inline JSON argument. The helper rejects duplicate JSON keys, unknown fields, and malformed values. It rejects them before it replaces the destination or adds history.

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
| `evidence.ref` | File: a relative path under the same path rules as scope. Commit: full lowercase 40- or 64-hex object ID. Test: a command or test identifier stored as text. Reference: a citation stored as text; the convention `memory:<slug>` (canonical `snake_case` slug) names an entry in the memory store explicitly and lets doctor report that entry's lifecycle status (see "Freshness and consistency"). All must be nonempty and single-line. |
| `evidence.observed_at` | Required valid UTC calendar timestamp, exactly `YYYY-MM-DDTHH:MM:SSZ`, recording when the supporting observation was made. |
| `evidence.note` | Optional nonempty single-line observation, such as the recorded test result. |

Text fields must be YAML-printable. The helper rejects control characters, unpaired surrogates, and Unicode line separators.

Record only observations that the session actually has. For unfinished work, leave evidence empty. Do not manufacture a result or timestamp.

## Compatibility and stable updates

- New `--handoff --handoff-data` writes produce `handoff_version: 2`.
- Supplying data upgrades an existing v1 handoff. The upgrade preserves its original `created` and its existing `expires`, unless `--expires` replaces the latter. `updated` advances as before.
- An existing v2 handoff that you update without `--handoff-data` keeps its scope and item values. The helper canonicalizes their JSON formatting.
- With replacement data, all previous item IDs must still be present. Mark an abandoned item `cancelled` instead of omitting it. Summary, status, evidence, and scoped paths can change. Repository identity cannot change. Use another handoff name for a different repository.
- Legacy direct helper calls without data still create v1 handoffs. Existing plain snapshots and v1 handoffs remain readable. There is no bulk migration.
- A plain save against an existing handoff still refuses. Unknown existing handoff versions and malformed v2 data also refuse, before archival or overwrite.
- The existing history limit, timestamp handling, expiry policy, and top-level ticket-citation scheme continue to apply. Expiry never deletes anything.

Work-item IDs belong to a handoff. They do not create or update tracker entries. Top-level `tickets:` continues to hold tracker pointers separately. When you regenerate a handoff, retain the ticket references that the next session still needs.

## Stored representation and diagnosis

`save-context.sh` remains the writer of the complete handoff. It emits these parts in order, before the closing frontmatter fence and the Markdown body:
1. its timestamps and optional tickets
2. `scope: {JSON object}`
3. `items:` with one `  - {JSON object}` line per item

This is a restricted, valid YAML format. It does not require a general YAML parser. Object keys are sorted. Unicode is preserved. Each structured value stays on one physical line.

`handoff-data.py` supplies the shared structural validation and rendering.

`doctor.sh` accepts both handoff versions. It reports malformed v2 data as a WARN. It labels recorded item evidence as not verified. Its existing timestamp, expiry, and ticket checks still run. It does not compare IDs against history. It does not assess evidence truth. The next section describes the freshness and consistency cues.

## Freshness and consistency

`doctor` assesses every valid v2 handoff with `handoff-data.py validate --assess --now <UTC> --stale-days <N>`. N is `SESSION_CONTEXT_STALE_DAYS` (default 7). This is the same knob as the file-age tier. A value outside 0–999999 is reported as a `WARN`, and both tiers fall back to 7.

The assessment is a pure function of the file and the supplied clock. It is deterministic and testable. It reads nothing else. It makes no truth claim.

| Level | Finding | Rule |
|---|---|---|
| WARN | evidence in the future | `observed_at` later than now + 300 s |
| WARN | evidence after update | `observed_at` later than the handoff `updated` + 300 s (the writer validates each timestamp's calendar form, not their relative order) |
| WARN | timestamps out of order | `created` later than `updated`, or `updated` later than now + 300 s |
| WARN | expired with open items | `expires` has passed and at least one item is `pending`, `in_progress`, or `blocked` |
| INFO | stale open item | an `in_progress` or `blocked` item whose newest `observed_at` is N days old or more; `pending` items and items without evidence are not stale (nothing has started), closed items are excluded |
| INFO | done, unverifiable only | a `done` item whose evidence is entirely `test`/`reference`; expected for work that has no local artefact, not an integrity defect |
| INFO | all items closed | every item is `done` or `cancelled`; the handoff is a candidate for promotion |

Findings keep the existing per-item summary lines. `doctor` reports them under its `context-handoff` section, separately from the mtime and expiry tiers.

**Explicit memory links.** The metadata assessment above reads only the handoff. One further check touches the filesystem.

A `reference` evidence whose `ref` is `memory:<slug>` names a memory entry explicitly. Write this link only when the session actually consulted that entry. Example: `{"kind": "reference", "ref": "memory:project_widget_firmware", "observed_at": "2026-09-16T10:00:00Z"}`.

`doctor` reads the top-level `status:` scalar of that entry from the memory store it has already resolved (the store `--store` selects, or the discovered one). It never follows a symlink. It never reads a candidate in `.inbox/`. It never looks anywhere else when the store is unavailable.

| Level | Finding | Rule |
|---|---|---|
| INFO | linked memory active | the file exists and its `status` is `active` (contents and completion remain unverified) |
| INFO | lifecycle unverified | the file exists but has no explicit `status`; or the memory store is unavailable, in which case one INFO per handoff says its links were not assessed and no fallback store is tried |
| WARN | linked memory stale / superseded / archived | the file's `status` is one of those; a cue to review the reference, not a contradiction of the work item |
| WARN | linked memory missing | nothing exists at `<store>/<slug>.md` |
| WARN | cannot assess lifecycle | the path exists but is a symlink, a special file, or not owned by the user, or the file has no complete frontmatter, a duplicate `status`, or an unrecognised value; or the store fails its safety validation |
| WARN | malformed memory link | `memory:` followed by anything other than a canonical slug |

A memory link is still `reference` evidence. It counts toward the "done, unverifiable only" cue, and `context-verify` reports it `unverified`.

Deliberately absent:
- Any link inferred from names. Item IDs are handoff-local. Only an explicit `memory:` reference is followed.
- Any comparison between two handoffs.
- Any tracker-line matching.
- Any verification of `file` or `commit` evidence against a repository. That is the job of `context-verify`, which needs an explicit repository binding that doctor does not have. The store resolution of doctor still uses Git to find the repository root.

## Verifying recorded evidence

`context-verify <name> --repository-id <snake_case> [--repo <path>] [--json]` runs `verify-context.sh`, which runs `context-verify.py` (it imports the shared parser). It performs local checks of the structured evidence. It is deliberately narrow, local, and read-only. It runs fixed Git queries (object type, `HEAD`, ancestry, shallow state). It never runs a recorded command. It never fetches.

- The caller binds the repository explicitly. The command compares `--repository-id` to the saved `scope.repository`. A mismatch is an input error (exit 2). The command never derives the ID from a directory name or remote URL. The command resolves `--repo` (default: the current git toplevel) to its toplevel, and the report names that toplevel.
- `scope.paths` and `file` evidence: the path exists under the toplevel and is a regular file. A directory is acceptable for scope paths. The command reports a symlink on the path as `unverified` and never follows it. It never reads contents.
- `commit` evidence: the object exists locally, is a commit, and is an ancestor of `HEAD`. A present commit that is not an ancestor is a mismatch. A wrong object type is a mismatch. In a shallow clone, a present, reachable commit is still `verified`. Only what the truncated history cannot establish is `unverified`. An unborn `HEAD` prevents the ancestry check only. The path and object-type checks still run.
- `test` and `reference` evidence, and items with no evidence, are reported `unverified`. For these evidence kinds, it does not execute, fetch, or resolve the references.
- Ticket citations are the concern of doctor. This verifier does not assess completion. Doctor assesses freshness and internal timestamp consistency (see "Freshness and consistency").

Exit codes:

| Exit | Meaning |
|---|---|
| `0` | Every local check passed. Nothing was left unverified. |
| `1` | At least one check is missing, mismatched, or unverified. |
| `2` | Input, schema, or environment error. This includes a plain snapshot or a v1 handoff, which carry no structured evidence. Regenerate with `--handoff` to get a v2. |

The JSON report (`report_version: 1`) lists every check with its category, reference, status (`verified|missing|mismatch|unverified`), detail, and owning item. It also holds `head`, `shallow`, summary counts, and a notice that restates these limits.

The human report prints these parts:
- the notice
- the resolved repository and `HEAD`
- one `STATUS <item-id>/<category> "<ref>": <detail>` line per check (the repository-binding and `scope` checks carry no item id)
- a summary line

The command opens the store through the same read-only gate that doctor uses. It never opens the store through the hardening resolver.

Load, list, share, diff, and remove continue to use the existing context mechanics. When you promote a handoff, treat the recorded scope, item statuses, and evidence as background. Preserve the relevant provenance in the proposal. These fields do not authorize a durable write or a source deletion.
