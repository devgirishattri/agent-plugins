# Changelog

## session-workspace 0.12.6 — 2026-11-03

- **Single service panes on demand.** `workspace start SESSION --pane NAME`
  (repeatable) starts only the named service panes of one session, such as
  the debug browser or one dev server. It creates the session with only those
  panes when it is not running, runs their declared commands, and keeps panes
  that already run. `workspace stop SESSION --pane NAME --confirmed` closes
  only those panes and leaves the session running; stopping the browser pane
  releases its port claim. NAME is the pane name or the part after
  `<project.id>-`, and only role `service` panes can be selected. `--pane`
  never attaches, and a subset start neither builds a `split_tree` layout nor
  restores or saves `retain_layout`.
- **Idle stop.** New optional per-pane `idle_stop_minutes` (1–1440, off by
  default) for service panes with a port to watch. A watcher samples the port
  every 30 seconds and stops the pane after the whole window with no use. For
  a dev server, use is any inbound connection. For the browser, use is CDP
  commands, read as the bytes clients sent (Linux `sock_diag`, macOS
  `nettop`). chrome-devtools-mcp holds its websocket open for its whole
  session and pings on it, so the open connection and its keepalive pings do
  not count. It reconnects by itself after the pane starts again. Where those
  bytes cannot be read, the browser counts connections instead. The stop and
  its reason are recorded in
  `$XDG_STATE_HOME/session-workspace/<project.id>/panes/<pane>.json`. A host
  that cannot count connections never stops a pane for idleness. The watcher
  needs `python3`.
- **Port safety.** `start --pane` refuses a dev-server pane (`port` plus
  `command`) whose port is already bound by another process, on every schema
  version, and names the holder (`... 3001 (web) is held by pid 4242
  (node)`). The schema-v5 full-start check names the holder too.
- **Status.** `workspace status` prints one CDP health line per browser pane
  (`browser: NAME http://127.0.0.1:PORT — up (...)  cdp_clients=N`) and, per
  pane, `running=yes|no`, the idle watcher and the last stop. `status` accepts
  `SESSION --pane NAME`. `workspace plan --json --running` adds a read-only
  `running` field per pane; plain `plan --json` is unchanged and still does
  not read tmux.
- **Harness (strict-v1).** The orchestrator's trusted-helper grammar admits
  `workspace-start.sh SESSION --pane NAME... [--no-attach]` and
  `workspace-stop.sh SESSION --pane NAME... --confirmed` (plus `--config` for
  this workspace) for configured service panes of that session only.
  **Behavior change:** executors and reviewers were already refused the
  lifecycle helpers, but could still run `workspace start` or `stop` through
  the `workspace` dispatcher on `PATH`, a copied dispatcher, or a script
  outside the cache. Every such route is now refused under
  `coordination.write`. Read verbs (`plan`, `status`, `doctor`) are
  unchanged.
- No config migration. Update both providers and restart agent panes so the
  new policy loads. To roll back, install the previous session-workspace
  release and remove any `idle_stop_minutes` keys, which older releases
  reject.

## knowledge 0.5.12 — 2026-11-03

- Validating the context store while another process saves no longer reports
  a healthy store as unsafe. Every release renames the writer lock into a
  short-lived `.knowledge-context-stale.<pid>` quarantine and then removes it.
  A validator that listed the quarantine just before its releaser removed it
  checked the type of a path that was already gone and failed with
  "writer-lock quarantine must be a directory". A quarantine that has vanished
  is now treated as a finished teardown; one that stays a non-directory is
  still rejected. This was the intermittent
  `validator_no_spurious_failure_under_writer_churn` failure in CI (about 1
  validation in 2,500, so a run of about 240 failed now and then). Outside
  tests it could fail `/context-list`, the doctor's context check, or a save
  that started just as another writer released, because each of these
  validates the store while the previous releaser may still be removing its
  quarantine.
- The writer-churn test now prints the first rejection's message, and
  `scripts/test-context-locks.py` has a deterministic case for both providers
  that removes the quarantine at exactly that check.
- No store migration.

## knowledge 0.5.11 — 2026-11-03

- `validate-links.sh` now decodes a percent-encoded markdown link target before
  it looks for the file. A link target is a URL, so a space in a file name is
  written `%20`, for example the target `../api/1.2%20List%20Items.md`. Before,
  the validator looked for the literal name `1.2%20List%20Items.md` and reported
  the link BROKEN although `../api/1.2 List Items.md` exists.
- Each `%HH` escape decodes to its byte: `%25` is a literal percent sign, and
  UTF-8 escapes such as `%C3%A9` resolve. A `%` without two hex digits after it
  stays as it is, so a link to `50%off.md` still resolves. A link written with
  a plain space still passes.
- A BROKEN line still shows the link as written. Its "expected at" path is now
  the decoded path, so it names the file that was looked for.
- `**Related**:` header references are plain file names in backticks, not URLs,
  and are not decoded.
- The Claude and Codex copies of `validate-links.sh` had drifted. They are now
  byte-identical, and `scripts/test-provider-parity.sh` fails if they differ
  again. Both copies now ignore spaces between `(` and the link target, as
  Markdown does; before, only the Codex copy did.
- `doctor` runs the same validator, so its `docs-links` warnings change in the
  same way. No migration.

## session-walkthrough 0.3.0 — 2026-11-03

- **Recorded bundle removed. The live tour is the only mode.** Every
  walkthrough request runs the live overlay tour in the already-running
  browser. A request for a recorded walkthrough or an evidence bundle gets
  a plain answer that the plugin offers only the live tour.
- Removed `scripts/walkthrough.sh` and `walkthrough.py` (the `validate`,
  `render` and `scope` subcommands), `manifest.schema.json`,
  `descriptor.schema.json`, the capture-target descriptors, the `WT-*` rule
  fixtures, and the `adapters`, `manifest`, `output`, `receipts` and
  `workspace-integration` references. The `SESSION_WALKTHROUGH_*` settings
  are gone with them. No capture pilot was ever recorded, so no supported
  capture target is lost.
- The plugin suite now checks the manifest, the skill, its links, the overlay
  `node:test` suite and the example, and fails if a shipped file names a
  removed bundle helper. It no longer needs `git`; it still needs `python3`
  and `node`.
- Migration: none for the live tour. Bundles recorded under
  `.tmp/walkthroughs/` stay where they are, but this version cannot validate
  or re-render them; keep 0.2.1 installed if you still need to.

## session-chat 0.17.21 — 2026-11-03

- A send or dispatch now checks that the recipient actually submitted the
  line. Before, a successful `tmux send-keys Enter` counted as delivered. Codex
  reads fast input as a paste burst and turns an Enter that arrives inside the
  burst into a newline, so a dispatch to an idle Codex pane could sit in its
  input line forever while the sender reported success and pane-health showed
  `ok`. After Enter the transport reads the recipient's input line (the last
  `›` line for Codex, the `❯` box for Claude Code; the transcript copy above it
  is ignored) and waits up to `SESSION_CHAT_SUBMIT_VERIFY_MS` (default 1000) for
  the text to leave it.
- If the text is still staged, the transport waits
  `SESSION_CHAT_SUBMIT_RETRY_DELAY_MS` (default 250), presses Enter once more
  and checks again. It never pastes a second copy. If the text is still
  staged after that, send and dispatch return the new status 4,
  "Unsubmitted …": the text stays in the input line and the durable copy stays
  queued, so it is not lost. Broadcast counts these as `unsubmitted`. Do not
  resend; press Enter in that pane.
- pane-health reports a pane whose input line holds an unsubmitted
  session-chat message as `UNSUBMITTED` (unsubmitted input). A pane whose send
  lock is held is skipped, since a send in flight stages its text briefly.
- The "landed" check now waits for the end of the payload, not only the first
  `id:` marker. A payload that reached the TUI in two pieces matched the
  header's marker early, and the Enter then submitted the header alone or
  landed in the tail's paste burst. This affected Claude Code as well as Codex.
- Claude Code submits on the first Enter, so on Claude Code panes the check
  only confirms the submit and sends nothing extra. Shells, paste placeholders
  and unrecognized screens keep the old behavior. `SESSION_CHAT_SUBMIT_VERIFY_MS=0`
  turns the check off.
- Same change in the Claude and Codex copies. A sender on 0.17.20 still
  reports these sends as delivered, so update both providers together.

## session-workspace 0.12.5 — 2026-11-03

- `harness-status` now prints the strict-v1 role floor before the guard
  packs. The old `guards:` line listed only the optional `harness.guards`
  packs, and agents read it as the complete enforcement list: executor panes
  refused a correct change, citing that line as proof that reviewer read-only
  and executor containment were not enforced. Both are part of the immutable
  floor and were enforced.
- The `floor (strict-v1, not configurable):` lines are generated from
  `harness-policy.py` itself (`--floor-json`): a new `ROLE_FLOOR` table names
  each role's floor clauses and the rule ids the policy raises for them, and
  the bracketed counts are read from the enforcement tables (`EDIT_TOOL_NAMES`,
  `READ_COMMANDS`, `READ_GIT`, `HELPERS`, ...). A pane with an accepted
  identity sees its own role and an `all roles` line. Without one, every role
  is shown, plus `<orchestrator> (confined)` when the plan has environment
  coordinators outside the project root.
- The text line `guards:` is renamed `optional guard packs:`. `--json` adds a
  `floor` object and a `probe` key. `guards` is unchanged, so `harness-doctor`
  and other readers keep working. `orchestrator.child_chdir` and
  `orchestrator.protected_file` are guard-pack rules, so they stay on the packs
  line and are not shown as floor.
- New `harness-status --probe`: the policy decides the built-in cases for the
  pane's own floor (`--probe-json`) through `evaluate_payload()`, the code path
  every hook decision takes, so a pane can check its floor without emulating
  another identity. Nothing is run or written. An unexpected decision prints an
  `UNEXPECTED` line and the script exits 1. The helper grammar accepts
  `--probe` for `harness-status.sh` in every role, directly and through
  `workspace.sh harness-status`; hook decisions are otherwise unchanged.
- Tests: per-role `harness-status` fixtures for the floor and packs lines, a
  copy of the scripts with an edited `READ_COMMANDS`/`ROLE_FLOOR` that changes
  the printed floor, a simulated enforcement drift that `--probe` reports, a
  check that every floor rule is raised by the policy and every
  reviewer/executor/orchestrator rule is floor or a named guard-pack rule, and
  probes for every pane of a schema-v5 environment topology.
- No config migration. Update both providers together and restart agents: a
  0.12.3 policy refuses `harness-status.sh --probe` with `helper.argv`.

## session-workspace 0.12.4 — 2026-11-03

- strict-v1 accepts the documented operands of the knowledge docs
  validators: `validate-links.sh [docs-directory]`,
  `check-todos.sh [docs-directory]` and
  `check-freshness.sh [docs-directory] [days-threshold]`. Before, the policy
  table gave all three a no-argument grammar, so an agent could check only the
  pane's whole cwd. A scoped pass such as
  `validate-links.sh <workspace>/docs/decisions` failed with
  `[helper.argv]: validate-links.sh accepts no arguments`.
- The directory must be literal and must resolve, symlinks included, to an
  existing directory inside the pane's own cwd: the workspace root for the
  orchestrator, the pane's checkout for executors and reviewers. A relative
  directory resolves against that cwd. The policy refuses a directory outside
  that scope, any `..` component, a symlink that points outside, a file, a
  second directory, a glob or `~`, and a value that starts with `-` (the
  validators pass it to `find`, which reads `-delete` as an expression). The
  freshness threshold is an integer from 1 to 3650.
- The other helper rules do not change: one literal `bash` segment, no shell
  composition or expansion, no extra arguments, and only the selected
  installed helper version.
- No config migration; update the plugin and restart affected agents.
  Downgrading to 0.12.3 restores the no-argument rule.

## session-walkthrough 0.2.1 — 2026-11-03

- **Strict Content Security Policy.** A `style-src` without `'unsafe-inline'`,
  nonce-based policies included, blocked the overlay's `<style>` element. The
  card then rendered unstyled below the page while the dry run still reported
  no overlap. The overlay now adopts a constructed stylesheet, which
  `style-src` does not block. Where constructed stylesheets are missing it
  falls back to a `<style>` element with the page's nonce. `status()` reports
  `styles`, and the dry run stops when it is `blocked`.
- **Animated targets.** A target inside a CSS transition, such as a menu that
  opens with a scale effect, was measured mid-animation. The ring stayed on
  the wrong rectangle and the card could cover the target. The overlay now
  waits for the target to stop moving (at most `settleTimeout`, 1000 ms).
- **Re-created targets.** When a framework replaced the highlighted node, the
  ring stayed on the old rectangle and `status()` reported no target until the
  next scroll. Placement now follows page DOM changes and the end of CSS
  transitions and animations, and `status()` queries a detached target again.
- **Tours never discard the user's edits.** In agent trials, four of five
  generated tours reset the whole form from `onClose` or a step's `setup`,
  which would also drop edits the user made during the tour. The docs now
  forbid that, document `onClose` (undo only what the tour set), and put
  field changes behind action buttons.
- Docs: the Vue 2 `el.__vue__` helper now steps down from the outermost
  instance on a shared root element. The reload line works under strict CSP
  through chrome-devtools; the fallback is to repeat the first injection.
  Route steps drop unsaved edits. Optional `sourcePath` injection for
  chrome-devtools-mcp 1.11.0 or later. SKILL.md gives the example's full path,
  which agents missed when they looked next to `SKILL.md`.
- No migration. Update the plugin; an open tour keeps the version it was
  injected with until it is injected again.

## knowledge 0.5.10 — 2026-11-03

- The context store's writer lock no longer treats a successful `mkdir` as
  ownership. uutils mkdir (Rust coreutils, the default on Ubuntu 25.10 and
  later) through 0.10.0 exits 0 when it loses the race to create a directory.
  The loser then failed to write its pid file and deleted the winner's pid and
  lock directory on the way out, so concurrent saves failed with "cannot
  publish writer-lock holder PID" and a third writer could take the lock
  while the first still held it. The holder now claims the lock only by
  creating its pid file exclusively (O_EXCL), and a writer that loses that
  create keeps waiting without touching anything.
- A stale lock (holder process gone) is taken over in place under an
  exclusively created `.reclaim` marker, instead of being renamed away under a
  marker made with `mkdir`, which uutils could hand to two waiters at once. A
  release renames the whole lock directory into the in-store quarantine, so a
  takeover marker in flight leaves with it. The marker is now an empty
  owner-only file. A 0.5.9 directory marker is still accepted and still
  blocks a takeover.
- Same protocol as the session-scheduler task locks and the session-chat
  locks. A store can be shared by Claude and Codex writers, and a 0.5.9 writer
  rejects the new file marker as unsafe, so update both providers together.
  No store migration.

## session-chat 0.17.20 — 2026-11-02

- Send and queue locks no longer treat a successful `mkdir` as ownership.
  uutils mkdir (Rust coreutils, the default on Ubuntu 25.10 and later) through
  0.10.0 exits 0 when it loses the race to create a directory, so two senders
  could hold one lock at once. The holder now claims the lock by creating its
  pid file exclusively (O_EXCL).
- A stale lock (holder process gone) is taken over in place under an
  exclusively created reclaim marker, instead of being deleted. Deleting it
  could remove a lock that another sender claimed after the waiter read the old
  pid, which gave the lock two holders on any coreutils. It happened most
  often when a sender released and exited while a waiter was checking it. A
  release now renames the whole lock directory away, so the lock path never
  shows a directory with no holder.
- A lock whose pid file cannot be written now fails the send with an error,
  instead of being held with no pid. On Codex, a lock released while a sender
  checks it is no longer refused as unsafe.
- Same protocol as the session-scheduler task locks. A recipient's queue lock
  is shared by Claude and Codex senders, and a 0.17.19 sender can still
  double-acquire it, so update both providers together. No store migration;
  restart affected panes after updating.

## session-walkthrough 0.2.0 — 2026-11-02

- **Live tour mode, now the default.** "Walk me through", "walkthrough",
  "tour", "show me the changes" and `/session-walkthrough` run a live,
  self-driven overlay tour in the already-running managed browser. The
  recorded bundle runs only on explicit request ("recorded walkthrough",
  "evidence bundle", "manifest"). The skill description and SKILL.md routing
  say so.
- New `scripts/tour/overlay.js`: a dependency-free overlay injected through
  chrome-devtools `evaluate_script`. It provides a highlight ring, a card of at
  most 350px placed beside the target without covering it, keyboard and
  accessibility support, setup/poll/actions/watch steps, sessionStorage reload
  recovery, an optional setInterval guard and SPA navigation hook, and a Close
  that leaves no residue.
- New `references/live-tour.md`: authority, runtime contract, step shape,
  authoring guidance and procedure (fresh tab, `emulate` not `resize_page`,
  geometry checks not element-scoped screenshots, GET-only dry run, hand-over).
- New walkable example `examples/live-tour/`: a synthetic demo page and a
  nine-step tour, runnable through chrome-devtools or locally with
  `demo.html?manual=1`.
- New `node:test` suite (`scripts/tour/tests/`) for placement math,
  navigation, cleanup, reload restore, the setInterval guard and the demo
  fixture. The plugin suite runs it, so `node` is now needed to run the
  plugin tests.
- Bundle mode: the 0.1.x contracts are unchanged and no pilot is recorded.
  The docs now warn that element-scoped screenshots crop wrongly when
  `devicePixelRatio` is not 1.
- No migration. Update the plugin; the next walkthrough request uses the live
  tour. To roll back, install session-walkthrough 0.1.1.

## session-scheduler 0.7.9 — 2026-11-02

- Per-task locks no longer treat a successful `mkdir` as ownership. uutils
  mkdir (Rust coreutils, Ubuntu's default coreutils since 25.10) through
  0.10.0 exits 0 when it loses the race to create a directory, so two writers
  could hold one task lock at once. The holder now claims the lock by creating
  its pid file exclusively (O_EXCL), and the stale-lock reclaim marker is an
  exclusively created file instead of a directory. Both providers share the
  change.
- Mixed versions interoperate: a 0.7.8 reclaim marker (a directory) still
  blocks a 0.7.9 reclaimer, and the reverse. A 0.7.8 pane on a uutils host
  can still double-acquire, so update both providers together. No store
  migration; restart affected panes after updating.

## session-workspace 0.7.1–0.11.7 — release notes moved from SKILL.md

Upgrade and rollback notes that lived in `skills/session-workspace/SKILL.md`.
The 0.10.0 notes are already recorded below. Add release dates from the
release commits.

- 0.7.1: reviewer writes are limited to the pane's own drafts directory.
  Earlier releases let reviewers write any top-level `.md`/`.txt` in the
  messages store. That reached other panes' pending dispatch files.
  Downgrading restores it.
- 0.7.1: executors may read the selected installed plugin version. No config
  migration; update the plugin and restart affected agents. Downgrading
  restores the earlier executor cache-read restriction.
- 0.7.4: path checks for attached short options, operands after `--`, and
  redirection targets. No config migration; restart agents after updating.
  Downgrading restores the 0.7.3 gap.
- 0.11.7: quoted literal paths and inert note text. No config migration;
  update the plugin and restart affected agents. Ships with scheduler 0.7.6.
  To roll back, install session-workspace 0.11.5 (and session-scheduler 0.7.5,
  commit 69041bb).

## session-workspace 0.10.0 — 2026-09-28

- Executors and reviewers may read complete delivered messages addressed to or
  sent by their validated pane, and existing own drafts, through the existing
  single literal read grammar. Delivered files must be private, owned regular
  files with one link, directly in the validated messages grant, with no
  traversal or symlink component. Filename endpoint parsing uses the complete
  validated topology and rejects ambiguous or unknown pairs.
- **Compatibility change:** reviewer shell reads no longer cover unrelated
  messages, transport state, peer drafts, or ungranted provider inboxes. Removed
  topology peers invalidate their historical payload access. Recursive reads
  through an ancestor of a message store are refused (`rg`, `find`, `du`,
  recursive `grep`, `ls -R`); name explicit safe subdirectories. Glob exclusions
  do not override this boundary. Child tool workdirs inside stores are refused,
  and executor operands resolve from the effective tool workdir.
- Close a pre-existing reviewer read bypass: the restricted grammar rejects
  NUL-separated file-list options in `sort`, `du`, `wc`, and `find`, including
  long-option abbreviations, because list contents hide additional operands.
  Ordinary executor in-checkout shell retains its existing floor; this does
  not claim subprocess isolation. Ordinary content reads remain allowed. Bundled `du`
  depth and `ls` ignore options cannot hide implicit recursive cwd traversal.
  Git receives no message-store read exception.
- Report scoped reads and denials as `coordination.message_read`, and recursive
  traversal/workdir denials as `coordination.message_traversal`, including in
  decision JSON. Own-draft native writes and coordinator rules are unchanged.
- No schema/store migration. Update both plugins and restart affected panes.
  Rollback restores the executor read failure and broader reviewer access.
  This remains a shell-operand guardrail: Claude native Read, arbitrary program
  internals, and same-user filesystem races are not isolated by this change.

## session-chat 0.17.13 — 2026-09-28

- Incoming file dispatches show a literal full-file read command before the
  inline body. Truncation guidance points to that file, including when the total
  hook-context cap truncates the body. Keep `SESSION_CHAT_DISPATCH_INLINE_MAX`
  as a display tunable; reading a full task does not depend on raising it.
  Claude's no-Python fallback now also reports byte-based inline truncation.
- Pair with session-workspace 0.10.0 for scoped executor/reviewer reads. Drafts
  and full transport copies keep their existing locations and send routing;
  notify/assist consent behavior is unchanged. Update both plugins and restart.

## session-workspace 0.9.0 — 2026-09-28

- **Behavior change:** orchestrator remote mutations through direct `gh` calls
  are now denied even when no argument resolves to a child checkout. This closes
  the direct-command named-repository and numeric API-route gap; projects relying on those
  mutations must route them to their executor. Audit mode reports the denial.
- Allow a closed set of literal orchestrator reads using `OWNER/NAME` repository
  selectors, positional `repo view`, and reviewed repository API endpoints with
  effective GET. API fields/input require explicit GET. File input still sends
  contents to GitHub; confined coordinators retain filesystem containment.
- Reject aliases, extensions, unsupported flags, wrappers, shell composition,
  dynamic operands and path-valued repository selectors. Emit distinct
  `orchestrator.gh_read`, `orchestrator.gh_mutation`, and
  `orchestrator.gh_unsupported` decision rules. Executor and reviewer rules are
  unchanged. No owner allowlist or new configuration key is introduced.
- No schema/store migration. Update both providers and restart affected agents;
  accept Codex hook trust if prompted. Rollback restores the old mutation gap
  and read restrictions. Git redirections and loops remain out of scope. The
  policy remains an argv guardrail for root and confined orchestrators, not
  subprocess isolation: script files and stdin-fed interpreters can still run
  gh. Withhold write-scoped orchestrator credentials where remote mutations
  must be impossible.

## session-workspace 0.7.0 — 2026-09-23

- Support root-scoped environment orchestrators with own-worker routing and task
  metadata, the existing root policy floor, and workspace-health guard output.
- Make the unbound root orchestrator optional when all worker environments have
  their own orchestrator; retain control-directory coordinator confinement.
- Allow command-less service shells and browser panes anywhere inside the project
  root while keeping command-bearing services inside their environment checkout.
- Add schema-v5 pane runtime overrides for mixed Claude/Codex roles. Schemas 1–4
  retain their existing plan and policy behavior.
- Report manual browser-profile migration guidance in doctor when changing from
  a singular project profile to per-session profiles; add a shared-root template.

## session-workspace 0.6.4 — 2026-09-23

- Require `rg --no-config` as the prefix for reviewer and scoped executor
  ripgrep reads, preventing inherited configuration from enabling symlink
  traversal or preprocessors.
- Reject hostname-program and compressed-search options in the restricted read
  grammar. General executor in-checkout shell permissions remain unchanged.
- Add real ripgrep controls for hostile configuration and normal searches on
  both provider trees.

## knowledge 0.3.28 — 2026-09-19

- Fix a docs-taxonomy scanner false positive: the exact `docs/decisions/README.md`
  folder index no longer requires decision naming or `decided` metadata. It remains
  covered by documentation link, freshness, and TODO checks.
- Fix memory-backlinks scanner false positives: fenced code blocks and single-backtick inline
  code spans no longer contribute links, warnings, or dangling counts in any
  graph mode. Prose links retain their existing resolution behavior.
