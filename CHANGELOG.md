# Changelog

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
- **Tours never discard the user's edits.** In agent trials, two of three
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
