# Changelog

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
