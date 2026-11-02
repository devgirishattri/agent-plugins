---
name: session-walkthrough
description: Live, self-driven walkthrough tours and recorded walkthrough bundles for a session's application changes. Use for any request to walk the user through a change ("walk me through", "walkthrough", "tour", "show me the changes", or /session-walkthrough) to run a live overlay tour in the already-running managed browser, read-mostly and never saving. Use the recorded bundle (scope fingerprints, a validated provenance manifest, stills or short clips, a portable HTML page under .tmp/walkthroughs/) only when the user explicitly asks for a recorded walkthrough, an evidence bundle or a manifest.
---

# session-walkthrough

After a coding session, show what changed in the running application. There
are two modes. A plain walkthrough request means the live tour.

## Modes

| The user says | Mode |
|---|---|
| "walk me through", "walkthrough", "tour", "show me the changes", `/session-walkthrough` | [Live tour](#live-tour) |
| "recorded walkthrough", "evidence bundle", "manifest", "provenance" | [Recorded bundle](#recorded-bundle) |

When the request is ambiguous, run the live tour. Never answer a walkthrough
request with a screenshot bundle or an improvised static screenshot page.

## Live tour

A live tour is an overlay injected into the app in the browser that is already
running. It highlights each new or changed element and explains it in a small
card that quotes the request line it covers. The user clicks through it. The
contract, the step shape and the full procedure are in
[references/live-tour.md](references/live-tour.md). A walkable example is in
`examples/live-tour/`.

Authority:

- The orchestrating agent builds and runs the tour in the managed browser that
  is already running. Executors and reviewers do not drive it.
- The tour is read-mostly. It never commits, pushes or deploys, and never edits
  application code.
- Annotations live only in the page DOM. Close removes them.
- Tour actions only set controls. The user performs any real save themselves.

Procedure (orchestrating agent):

1. Check the preconditions. The managed browser and the app server must
   already run. Never start, restart or replace either; if one is down, ask the
   user. The session must be authorized; otherwise mark role-gated steps "not
   verified".
2. Open a fresh ordinary tab with chrome-devtools `new_page`. Never navigate a
   tab the user is working in.
3. Read `window.innerWidth` and `window.devicePixelRatio`. For phone layouts use
   `emulate`, never `resize_page`, and reset it afterwards.
4. Write the tour file in your scratch area, with one step per new or changed
   element. Each step quotes its request line or is labelled "Design decision".
   Order: overview, changed surfaces, blocked or disabled states, the result,
   and a final "Not shown" step. Prefer synthetic or demo records; never write
   customer data into the file.
5. Read the full text of the overlay and the tour file. Inject both, overlay
   first, in one `evaluate_script` function. The overlay is at:

   ```
   ${CLAUDE_PLUGIN_ROOT}/scripts/tour/overlay.js
   ```

6. Dry-run every step with `SessionWalkthroughTour.goTo(i)`. Check placement
   with the returned geometry (`targetRect`, `cardRect`, `overlaps`) or
   `getBoundingClientRect()`, not element-scoped screenshots. Confirm that no
   save happened: only GET requests in the network list, page data unchanged.
   Return to step 1.
7. Hand over. Once the user starts clicking, stop driving the tab: no
   navigation and no re-injection over their work.
8. Optionally write a short local note with the steps, the records used and
   the unverified items.

## Recorded bundle

Use this mode only on explicit request, for recorded provenance. A recorded
walkthrough is a local, inspectable bundle: `manifest.json` (provenance),
`index.html` (portable page), stills, and optional short captioned clips. It
records observations. It is not a test result, an approval, or an upload.

### Current status

The bundle mode ships the contracts, synthetic fixtures, and three helpers: a
manifest validator, a page renderer and a scope fingerprint helper (see
[Helpers](#helpers)). It ships no capture helper. No pilot is recorded, so no
capture target is supported yet (see
[references/adapters.md](references/adapters.md)). Before a bundle run, check
that the output root is git-ignored in the app repository and that synthetic
demo data exists; stop and report when either is missing.

### Authority boundary

- A walkthrough never grants commit, push, deploy or upload authority. The
  scheduler ledger and session-chat archive remain the approval evidence.
- The executor captures and assembles. The orchestrator adds scope, journey,
  baseline and demo-data instructions to the assignment packet. The reviewer
  reads artifacts and verifies hashes. A re-observation is a recapture request
  to the executor; the reviewer does not drive the app in v1.
- No automatic replay of actions that may change application state. No AI
  analysis, cloud device service, remote renderer or automatic upload.
- Capture only the configured window, app, device or origin. Use synthetic
  demo data. When a capture shows a secret, discard it and recapture after
  fixing the source. Blurring or a text scan does not prove pixel safety.
- Raw media stays under the git-ignored run directory. Never promote it into
  memory or documentation.

### Procedure (executor)

1. Scope before editing. Record HEAD, the task WHERE paths, and bounded
   fingerprints of the dirty tree with `scope start` (see [Helpers](#helpers)).
   Never stash, reset or switch branches in the shared checkout.
2. Plan the journey from the assignment packet: changed experiences, useful
   before states, seeded demo data, target identity, expected observations.
3. Capture a baseline when it is safely available. Otherwise record
   `before unavailable` with the reason.
4. Implement and test through the normal workflow.
5. Record a build receipt, or `unverified` with the reason. See
   [references/receipts.md](references/receipts.md).
6. Capture stills for visual deltas and clips of at most 180 seconds for
   interactions. On the web route, element-scoped screenshots crop the wrong
   rectangle when `devicePixelRatio` is not 1 (browser zoom other than 100%).
   Take viewport screenshots and check element geometry with
   `getBoundingClientRect()` instead. Register every asset with its SHA-256,
   media type, recording kind and caption cues.
7. Scope again at the end with `scope end` (see [Helpers](#helpers)). Map every
   changed path to a chapter or an explicit omission such as
   `omitted: non-visual`.
8. Validate the manifest and render `index.html` with `validate` and `render`
   (see [Helpers](#helpers)). Put the manifest path and SHA-256 in the
   `task-review` note.

Stop and report when the output root is not git-ignored, a prerequisite is
missing, the target is ambiguous, or the source or build drifted after
capture. Record failures as `failed` or `skipped` chapters with reasons; keep
partial output.

## Helpers

`scripts/walkthrough.sh` is the one entry point. It runs the validator, the
renderer and the scope helper with python3.

Run exactly one literal Bash segment per call:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/walkthrough.sh" <subcommand> ...
```

Put no `export`, `env` or variable assignment before it. Chain, pipe,
redirect or substitute nothing around it. Pass every path and option as a
plain argument.

| Subcommand | Purpose | Key arguments | Exit codes |
|---|---|---|---|
| `validate` | Check the manifest against the schema and every `WT-*` rule. Print one `WT-CODE path message` line per failure. | `--manifest FILE --run-dir DIR` (read-only; trusts `committed_changes`), or `--run-dir DIR` alone to also check the run directory's place and re-derive `committed_changes`; `--json` | 0 valid, 1 invalid, 2 unusable input or unsafe location |
| `render` | Check the run directory, take its lock, then read and validate the manifest and assets, then write `index.html`. Print the manifest SHA-256. | `--run-dir DIR`, optional `--manifest FILE`; `--output FILE` inside the run directory | 0 written, 1 invalid manifest, 2 unusable input or unsafe location |
| `scope` | `start` writes `scope-start.json`. `end` also writes `scope-end.json` and `scope-summary.json`; paste its `repository`, `task` and `scope` blocks into the manifest. | `start` or `end`, `--repo GIT_ROOT`, `--where PATH`, `--reported PATH`, `--run ID` or `--run-dir DIR`, `--shared-tree` | 0 recorded, 2 unusable input, containment or lock refusal |

Run directories live under the git-ignored output root. `render` and `scope`
write only there. For `render`, `--manifest` only selects the input file. It
never relaxes this rule. Both refuse a path outside the root, a symlink in the
path, or a live lock. They check the location before they take the lock and
again after. `render` reads the manifest and the assets only while it holds the
lock. `validate --run-dir` alone also needs both HEADs to be available commits
on one linear history. No helper edits ignore rules. `scope start` refuses to
overwrite an existing `scope-start.json`.

## Contracts

| Reference | Contents |
|---|---|
| [references/live-tour.md](references/live-tour.md) | Live tour contract: authority, overlay runtime, step shape, placement, resilience, cleanup, authoring and procedure |
| [references/manifest.md](references/manifest.md) | Manifest groups, fingerprint canon, `WT-*` validation rules, rendering requirements; shape in `scripts/manifest.schema.json` |
| [references/adapters.md](references/adapters.md) | Descriptor contract, observe versus drive, recording kinds, shipped floor descriptors, probes, telemetry opt-outs; shape in `scripts/descriptor.schema.json` |
| [references/receipts.md](references/receipts.md) | Receipt kinds and derived freshness |
| [references/output.md](references/output.md) | Run directory, run id, containment, lock, cancellation, retention, tunables |
| [references/workspace-integration.md](references/workspace-integration.md) | Proposed workspace fields and orchestration touch points; design only |

Synthetic fixtures in `scripts/fixtures/` show complete valid manifests and
one negative per rule. Each negative is paired with its valid control.

## Tunables

Env-only, read per invocation by the helpers; changing them needs no restart.
See [references/output.md](references/output.md) for their meaning.

| Variable | Default |
|---|---|
| `SESSION_WALKTHROUGH_OUTPUT_ROOT` | `.tmp/walkthroughs` |
| `SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES` | `8388608` |
| `SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS` | `10` |
