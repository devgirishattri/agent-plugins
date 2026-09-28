# Changelog

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
