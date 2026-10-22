# Workspace integration (design, not implemented)

These fields are proposed for `session-workspace`. They do not exist in the
current `workspace.schema.json` (versions 1–5), `compute-plan.jq`,
`workspace-browser-config.sh` or `harness-policy.py`. Adding them is a
session-workspace change. That change must ship schema, normalized plan,
provider rendering and exact helper argument admission together, with paired
executor grant and reviewer denial controls.

## Proposed block

```json
{"walkthrough": {
  "enabled": false,
  "adapter": "web-chrome-devtools",
  "target": {"origin": "http://127.0.0.1:4173"},
  "output_root": ".tmp/walkthroughs",
  "recording": {"clips": false, "max_seconds": 60},
  "receipt": {"kind": "web-build-info", "path": "/__build"}
}}
```

| Field | Rule |
|---|---|
| `enabled` | Default `false`. Absent block means disabled; existing configurations change nothing. |
| `adapter` | A shipped descriptor id. Unknown ids fail validation. |
| `target` | Exactly one identity matching the descriptor's `target_kind`: `origin`, `window_title`, `bundle_id` + `udid`, or `device`. |
| `output_root` | Repository-relative, inside the project root, git-ignored. |
| `recording` | `clips` opt-in; `max_seconds` at most 180. |
| `receipt` | `web-build-info` with a path, `native-build`, or `authorized-build-output`. No command strings. |

Gate the block behind a new `schema_version` so a mixed plugin/version pair
reports incompatibility instead of silently accepting unknown options. Reuse
existing environment and secret contracts for telemetry opt-outs. The browser
renderer must learn the opt-out flags before `web-chrome-devtools` can claim
`egress: opt-out-configured`.

## Standalone consumption

The consumer plugin must work without starting tmux. Its validated input is
the manifest and run directory. Scope and target come from explicit
`--where`, `--reported` and target arguments. When a normalized workspace plan
exists it supplies the same values; it never replaces explicit executor input.

## Orchestration touch points

- Assignment packet: add scope (WHERE), journey, baseline and demo-data
  instructions. No new packet format.
- `task-review` note: carries the manifest path and SHA-256. No new note field.
- Reviewer: reads the run directory, re-hashes assets, compares the manifest
  hash with the note, and requests recapture from the executor on drift. The
  reviewer does not drive the app or capture in v1.
- No new approval ledger, event store, Stop hook or device lease.
