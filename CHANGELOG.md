# Changelog

## knowledge 0.3.28 — 2026-09-19

- Fix a docs-taxonomy scanner false positive: the exact `docs/decisions/README.md`
  folder index no longer requires decision naming or `decided` metadata. It remains
  covered by documentation link, freshness, and TODO checks.
- Fix memory-backlinks scanner false positives: fenced code blocks and single-backtick inline
  code spans no longer contribute links, warnings, or dangling counts in any
  graph mode. Prose links retain their existing resolution behavior.
