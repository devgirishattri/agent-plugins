# Changelog

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
