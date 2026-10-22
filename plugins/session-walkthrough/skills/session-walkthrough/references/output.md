# Output contract

## Run directory

Default output root: `<repository root>/.tmp/walkthroughs`. Each run owns
`<output root>/<run-id>/`:

| Entry | Meaning |
|---|---|
| `manifest.json` | Provenance record; see [manifest.md](manifest.md) |
| `index.html` | Portable page rendered from the validated manifest |
| `scope-start.json`, `scope-end.json` | Scope snapshots copied into `manifest.scope` |
| `assets/` | Flat directory of stills and clips; names match the asset path grammar |
| `.lock/` | Run-directory lock (`pid` inside) while a helper writes |

The run directory is an artifact directory, not a launch-inherited store. It
is never exported as an environment variable by a hook, skill or script.

## Run id

`^[a-z0-9][a-z0-9-]{3,63}$`. Generated ids use
`wt-<UTC yyyymmdd-hhmmss>-<4 hex>`. The directory name equals `run.id`.

## Containment

Before the first write, and again before rendering:

1. Resolve the output root. It must be inside the repository root after
   resolving symlinks, and no component may be a symlink.
2. `git check-ignore` must report the output root as ignored. A failed check
   stops the run. The helper never edits `.gitignore` or any ignore rule.
3. Every asset path must match the flat `assets/` grammar and resolve to an
   owned regular file inside the run directory.
4. Reject traversal, absolute paths, unexpected file types and writes outside
   the selected run directory.

## Lock

`.lock/` is created with `mkdir` and holds the writer's pid. A helper that
finds the lock rechecks that it still exists before reporting it unsafe. The
holder can release between two stat calls. A dead holder's lock is reclaimed;
a live holder's lock is a refusal. The lock protects the run
directory only. It does not serialize a shared browser, simulator or device
across runs; the scheduler assignment serializes capture on one target, and a
helper refuses known contention instead of inventing a lease store.

## Failure, cancellation and drift

- A failed chapter keeps its bounded reason and any safely captured asset.
- A cancelled capture stops only the recording process this run started, marks
  the run `cancelled` or `partial`, and keeps partial output.
- A crash never becomes a completed run: `complete` requires `finalized_at`.
- If the source or build changes after capture (fingerprint or receipt drift),
  the affected chapters are invalid. Recapture; do not edit the manifest to fit.

## Retention and rollback

Nothing deletes reports automatically. Remove a run with
`rm -r .tmp/walkthroughs/<run-id>` after confirming the id. A later cleanup
command, if added, is dry-run by default and never touches unrelated `.tmp`
content. Rollback of the capability disables its configuration and removes
managed integration entries; prior reports and canonical task state stay.

## Tunables

Env-only, read per invocation by `scripts/walkthrough.py`; no restart needed.
A non-numeric value falls back to the default.

| Variable | Default | Meaning |
|---|---|---|
| `SESSION_WALKTHROUGH_OUTPUT_ROOT` | `.tmp/walkthroughs` | Repository-relative output root; must be inside the repository and git-ignored |
| `SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES` | `8388608` | Largest file hashed into a scope snapshot; larger files are listed with `omitted: size` |
| `SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS` | `10` | How long a helper waits for a live run-directory lock before refusing |
