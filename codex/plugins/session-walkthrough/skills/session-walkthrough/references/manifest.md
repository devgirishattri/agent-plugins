# Manifest contract (schema_version 1)

`manifest.json` is the provenance record of one walkthrough run. The structural
shape is `scripts/manifest.schema.json` (JSON Schema draft-07, every object
closed with `additionalProperties: false`). The cross-field rules below are the
part a schema cannot express. The validator enforces both. A valid manifest
proves what was captured and how it binds to the source. It does not prove a
build is fresh, an observation is correct, or that anyone approved anything.

## Groups

| Group | Required meaning |
|---|---|
| `run` | Run id, timestamps, status, generator plugin/version/provider, host platform |
| `repository` | Project id (never a path), start/end HEAD, branch, dirty state at the end |
| `task` | Workflow/task/executor identity, task WHERE paths, executor-reported changed paths |
| `scope` | Start/end fingerprints (hashes only), committed changes between the two HEADs, derived changed paths with attribution, discrepancies, shared-tree flag, limitations |
| `target` | Platform, descriptor id, target identity (origin, bundle, app, window, device), viewport, tool versions, claimed capabilities |
| `build` | Freshness (`verified`, `verified-commit-only`, `unverified`, `contradicted`), typed receipt or `null`, derived unbound paths, reason |
| `chapters` | Scenario, actions, checkpoints, source paths, before/after assets, observation, executor-reported assertions, status and reason |
| `assets` | Flat relative path, media type, SHA-256, size, recording kind, duration/codec, caption cues, capture tool, privacy review |
| `coverage` | Every scoped path mapped to chapters or an explicit omission, plus overall limitations |
| `privacy` | Demo-data status, capture scope, egress status, notes |

Timestamps are UTC `YYYY-MM-DDTHH:MM:SSZ`. Hashes are lowercase hex SHA-256.
Repository paths are POSIX and relative, with no `.` or `..` segment anywhere.
A WHERE prefix matches by whole component: `src` covers `src/x`, not
`src-other/x`, and `src/a.ts` covers only itself. Text fields are bounded
(`line` 200 characters on one line; `text` 2000 characters). The renderer
escapes every field; the manifest never trusts its own strings.

## Fingerprints

A scope snapshot lists the dirty working tree as entries: tracked modifications
and non-ignored untracked files, each with a state, a SHA-256 and a size. Files
larger than `max_bytes`, non-regular files, unreadable files and deletions carry
`sha256: null`, `bytes: null` and an `omitted` reason. `fingerprint` is the
SHA-256 of the canonical JSON of `entries`: entries sorted by `path`, object
keys sorted, separators `,` and `:`, ASCII-escaped output. Contents are never
stored.

Entries describe the dirty tree only. Changes that were committed between the
two snapshots are listed separately in `committed_changes`, so a clean tree at
both ends cannot hide a committed change (`WT-HEAD-DRIFT`). A path that leaves
the dirty list without a commit was restored, reverted or otherwise not
observed; the manifest records `unknown`, never `deleted`, for it. A
fingerprint shows that paths changed between two moments; it never proves who
changed them.

## Validation rules

Each rule has a stable code. The validator reports every failing code with the
JSON path, then exits non-zero if any failed. Fixtures in `scripts/fixtures/`
pair each negative with a valid control.

| Code | Rule |
|---|---|
| `WT-JSON-DUPLICATE-KEY` | Duplicate object keys are rejected before any other check. |
| `WT-SCHEMA-VERSION` | `schema_version` must be `1`. Unknown versions fail closed. |
| `WT-SCHEMA-SHAPE` | Any violation of `manifest.schema.json`: unknown or missing field, wrong type, enum, pattern or bound. |
| `WT-RUN-ID` | `run.id` matches `^[a-z0-9][a-z0-9-]{3,63}$`. In run-directory mode it equals the directory name. |
| `WT-RUN-STATUS` | `complete` requires `finalized_at` and no chapter or coverage entry with status `failed` or `skipped`. `partial` requires `finalized_at`. |
| `WT-SCOPE-START` | `scope.start` is `null` exactly when `start_unavailable_reason` is set. Without a start snapshot, every changed path has attribution `before unavailable` and change `unknown`, and exactly one `before-unavailable` discrepancy with `path: null` exists. |
| `WT-SCOPE-FINGERPRINT` | Each snapshot's `fingerprint` equals the recomputed digest of its `entries`. |
| `WT-SCOPE-ENTRY` | An entry has `sha256` and `bytes` `null` exactly when `omitted` is present. |
| `WT-HEAD` | `repository.head_end` equals `scope.end.head`. `repository.head_start` equals `scope.start.head`, or `null` without a start snapshot. `dirty_at_end` is true exactly when `scope.end.entries` is non-empty. |
| `WT-HEAD-DRIFT` | With a start snapshot whose `head` equals `end.head`, `committed_changes` is empty. When the heads differ, `committed_changes` equals the endpoint diff `git diff --name-status <start.head> <end.head>`: the net change between the two commits, which may be empty (an empty commit, or a change followed by its revert). Paths touched by intervening commits and reverted are not listed. `start.head` must be an ancestor of `end.head`; the scope helper refuses any other history. Run-directory mode re-derives the list exactly when the repository is available; fixture mode cannot verify it and trusts the manifest. Without a start snapshot `committed_changes` is empty. |
| `WT-SCOPE-CHANGED` | The observed set O: with a start snapshot, every path whose entry exists in only one snapshot or differs in `state` or `sha256`, plus every `committed_changes` path. `change` is the end entry's state when the path has one (`untracked` becomes `added` for a path absent from the start snapshot and `modified` otherwise); otherwise the committed change when the path is in `committed_changes`; otherwise `unknown`, because a path that left the dirty list without a commit was restored, reverted or not observed, and the snapshots cannot establish deletion. `deleted` comes only from an end entry or a committed change. Without a start snapshot, O is exactly `task.reported_paths` with change `unknown`. `changed_paths` lists exactly O. `in_where` is true when the path equals a `task.where` entry or starts with that entry followed by `/`. `reported` is true when the path is in `task.reported_paths`. Attribution is `reported-and-observed` when reported, otherwise `observed-only: attribution uncertain`; without a start snapshot it is `before unavailable`. |
| `WT-SCOPE-DISCREPANCY` | Exactly these discrepancies, one per kind and path, with no others and no duplicates. With a start snapshot: `outside-where` for every changed path with `in_where` false; `observed-not-reported` for every changed path with `reported` false; `reported-not-observed` for every reported path not in O; `fingerprint-omitted` for every path with an omitted entry in either snapshot. Without a start snapshot: one `before-unavailable` with `path: null`; `outside-where` for every reported path outside `task.where`; `fingerprint-omitted` for every omitted end entry. In both cases exactly one `shared-tree: attribution uncertain` with `path: null` when `shared_tree` is true. |
| `WT-ADAPTER-UNKNOWN` | `target.adapter` and every `assets[].tool.adapter` name a shipped descriptor. `target.platform` equals the target descriptor's platform. |
| `WT-TARGET-IDENTITY` | `target.identity` holds exactly the keys for the platform. `web`: `origin`. `electron`: `origin`, or `app_name`, `window_title` and `bundle_id`. `macos`: `app_name`, `window_title` and `bundle_id`. `ios-simulator`: `udid` and `bundle_id`, optionally `device`. `android-emulator`: `device` and `bundle_id`. Any other key set is ambiguous and fails. |
| `WT-TARGET-CAPABILITIES` | Claimed `target.capabilities` cannot exceed the descriptor: `observe` needs `screenshot`, `record` needs `record`, `drive` is the descriptor value or `none`. |
| `WT-RECEIPT-BINDING` | `web-build-info` requires an `origin` binding; `native-build` requires an `installed` binding; `authorized-build-output` accepts either. An `origin` binding requires platform `web` or `electron` and `binding.origin` equal to `target.identity.origin`. An `installed` binding requires platform `macos`, `ios-simulator` or `android-emulator`, and `binding.identity` equal to the target's binding keys: `bundle_id` for macOS; `udid` and `bundle_id` for iOS Simulator; `device` and `bundle_id` for Android emulator. |
| `WT-BUILD-FRESHNESS` | Derived in order. No receipt: `unverified`. A binding that violates `WT-RECEIPT-BINDING`, a non-null `installed_sha256` different from `product_sha256`, a `source.revision` different from `repository.head_end`, or a non-null `source.fingerprint` different from `scope.end.fingerprint`: `contradicted`. An `installed` binding with `installed_sha256: null`: `unverified`. A null `source.fingerprint` with a non-empty `scope.end.entries`: `verified-commit-only`. Otherwise `verified`. The declared value must equal the derived value. |
| `WT-BUILD-CONTRADICTED` | A manifest whose derived freshness is `contradicted` fails. Rebuild, recapture, then validate again. |
| `WT-BUILD-UNBOUND` | `build.unbound_paths` equals, sorted and unique: every `scope.end.entries` path when freshness is `verified-commit-only`; every end entry path with `omitted` set when freshness is `verified`; empty otherwise. |
| `WT-CHAPTER-ID` | Chapter ids are unique. |
| `WT-CHAPTER-ASSET` | `before.asset` and `after.asset` reference existing asset ids. |
| `WT-CHAPTER-BEFORE` | `before.asset` is `null` exactly when `before.unavailable_reason` is set. |
| `WT-CHAPTER-EVIDENCE` | `demonstrated` requires `after.asset`, `observation` and `captured_at` set and `reason` `null`. `failed` and `skipped` require `reason`. |
| `WT-CHAPTER-SOURCE` | Every chapter `source_paths` entry appears in `coverage.paths`. |
| `WT-ASSET-ID` | Asset ids are unique. `normalized_from` references a different existing asset. |
| `WT-ASSET-PATH` | The path matches `assets/<safe-name>.<ext>`, is unique, and in run-directory mode resolves to an owned regular file with no symlink component inside the run directory. |
| `WT-ASSET-HASH` | `sha256` and `bytes` equal the file's digest and size. |
| `WT-ASSET-MEDIA` | The extension agrees with `media_type`, and the file's leading bytes match that type's signature. |
| `WT-ASSET-KIND` | Image types require `stills`, `duration_seconds: null`, `codec: null`, `frame_interval_seconds: null` and no captions. Video types require `continuous` or `frame-sampled`, a duration and a codec (`unknown` allowed). `frame-sampled` requires `frame_interval_seconds`; `continuous` requires it `null`. A set of stills is never a continuous recording. |
| `WT-ASSET-KIND-ADAPTER` | The asset's `recording_kind` is one of its descriptor's `recording.kinds`, and `duration_seconds` is at most the descriptor's `max_duration_seconds`. |
| `WT-ASSET-DURATION` | `duration_seconds` is at most 180. Prefer short chapters. |
| `WT-CAPTION-RANGE` | Cues satisfy `start < end <= duration_seconds`, are sorted by `start`, and do not overlap. |
| `WT-COVERAGE-UNMAPPED` | The set of `coverage.paths[].path` equals the union of `scope.changed_paths[].path` and `task.reported_paths`. Every scoped change is demonstrated or explicitly omitted. |
| `WT-COVERAGE-CHAPTER` | A `demonstrated` entry lists at least one chapter. Each listed chapter exists, is `demonstrated`, and lists the path in `source_paths`. |
| `WT-COVERAGE-REASON` | `omitted: *`, `failed` and `skipped` entries require `reason`. `omitted: unobserved` is for a path whose change is `unknown`. |
| `WT-PRIVACY` | `capture_scope: desktop` requires at least one `privacy.notes` entry. |
| `WT-OUTPUT-CONTAINMENT` | Run-directory mode: the manifest is `<run-dir>/manifest.json`, the run directory is inside a git-ignored output root, and no component of that path is a symlink. See [output.md](output.md). |

## Rendering requirements

The renderer reads a manifest that already passed validation and writes
`index.html` next to it.

- Open `index.html` directly from the file system. No local server, remote
  script, stylesheet, font, image or network request. All CSS and JS are inline.
- Escape every manifest string in HTML text and attributes. Serialize the inline
  JSON copy of the manifest with `<`, `>`, `&`, U+2028 and U+2029 escaped so a
  value such as `</script>` cannot close the script element.
- Render caption cues from the inline JSON. An inline script follows the
  clip's `timeupdate` events. Also list every cue as static text under the
  clip. Do not depend on a sibling `<track>` file; `file://` playback of such
  tracks was reported blocked and has not been reproduced locally.
- Keep asset references relative so the run directory can be moved as a whole.
- Show `build.freshness` verbatim as a label and list `build.unbound_paths`
  under it. `verified-commit-only` must say that the commit is bound and that
  the listed working-tree paths are not.
- Show `before unavailable`, failed and skipped chapters, committed changes,
  discrepancies and limitations visibly. A report must stay readable when
  some chapters failed.
- Label recording kinds. Present `frame-sampled` and `stills` as what they are,
  never as a continuous recording.
