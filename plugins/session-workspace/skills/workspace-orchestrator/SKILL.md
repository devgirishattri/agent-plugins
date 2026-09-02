---
name: workspace-orchestrator
description: Coordinate a schema-v4 session-workspace reviewed Git lifecycle across orchestrator, executor, and reviewer panes. Use for workspace status, plan review, executor dispatch, post-execution review, commit, push, deploy, selftest, prompt preview, or when replacing equivalent project-local orchestration commands.
---

# Workspace Orchestrator

Use this skill only from the configured semantic orchestrator pane. It turns a
validated `schema_version: 4` `orchestration` block into one provider-neutral
workflow; every repository mutation still runs in the target's configured
executor pane.

## Start here

1. Resolve the normalized plan with `--json`: Claude uses
   `/session-workspace:workspace-plan --json`; Codex uses
   `$session-workspace:workspace-plan --json`.
2. Require `.orchestration.active == true`, `.harness.active == true`, and a
   matching live identity. Claude uses `/session-workspace:harness-status`;
   Codex uses `$session-workspace:harness-status`.
3. Select exactly one normalized target by `id`. Use only its resolved `cwd`,
   `executor`, `reviewer`, remote, branches, deploy strategy, and harness TTLs.
4. Read [references/lifecycle.md](references/lifecycle.md) and execute the
   workflow matching the user's intent.

Stop if the target is absent/ambiguous, identity does not match, a configured
pane is unhealthy, or the plan/config changed after evidence was collected.
Never infer missing coordinates or fall back to a project-local command.

## Immutable boundary

- The order is status → plan → independent plan approval → explicit user
  confirmation → scheduler assignment → independent audit → separately
  authorized commit → push → deploy.
- Plan approval is a correlated reviewer reply containing an explicit
  `APPROVE` token. Audit approval is a reviewer-authored scheduler closing note
  (or correlated reply) containing explicit `APPROVE`. A dispatch, a pane
  scrape, `task-review`, or `task-done` alone is not approval.
- Plan and audit evidence expire using the normalized harness
  `plan_review_ttl_minutes` and `audit_ttl_minutes`. Parse `Z` and numeric-offset
  timestamps to epoch seconds before comparing them.
- User confirmations are conversational gates. Report them honestly; neither
  the harness nor scheduler can prove them.
- The orchestrator coordinates only. Commit, fetch, push, checkout, merge, and
  fast-forward alignment are dispatched to and executed by the target executor.
- JSON supplies literals, not executable policy. Project-specific build/test
  requirements still come from the target repository's `AGENTS.md`; include
  them in review and assignment packets without treating them as config code.

Use installed `session-chat` skills for pane health and correlated transport,
and installed `session-scheduler` skills for every implementation assignment.
Never pin marketplace cache paths. Never create a parallel evidence log: the
pinned scheduler ledger and session-chat archive are canonical.

## Intent mapping

Natural-language requests map to: status, plan review, executor dispatch,
post-execution review, commit authorization, push authorization, deploy
authorization, selftest, or prompt preview. Historical project-local names
such as `status`, `plan`, `dispatch`, `review`, `commit`, `push`, `deploy`,
`selftest`, and `prompt` map to these workflows; do not require the retired
aliases to exist.

## References

- [references/lifecycle.md](references/lifecycle.md) — exact gates, packets,
  Git floor, deploy preflight, and evidence rules.
- [references/workspace-json.md](references/workspace-json.md) — schema-v4
  configuration contract and example.
