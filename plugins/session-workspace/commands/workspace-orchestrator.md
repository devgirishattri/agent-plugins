---
description: Coordinate the schema-v4 reviewed Git lifecycle (status/plan/dispatch/review/commit/push/deploy) across configured executor/reviewer panes
argument-hint: "<intent, e.g. 'status', 'plan review for <target>: <task>', 'authorize push for <target>'>"
allowed-tools: Bash(bash:*)
---

## Task

Run the reviewed Git orchestration workflow for this workspace with the user's
intent: `$ARGUMENTS`

## Instructions

Load and follow the `session-workspace:workspace-orchestrator` skill — it is
the complete, provider-neutral contract for this command. Do not improvise a
lifecycle of your own, and never weaken, reorder, skip, or duplicate any of its
gates.

Ground rules the skill enforces (summarized here only so you refuse early):

1. Only the configured semantic **orchestrator** pane may run this workflow.
   Resolve the normalized plan first (`workspace-plan` with `--json` via the
   installed helper) and require `.orchestration.active == true`,
   `.harness.active == true`, and a live `harness-status` identity MATCH.
2. Map `$ARGUMENTS` to exactly one workflow — status, plan review, executor
   dispatch, post-execution review, commit authorization, push authorization,
   deploy authorization, selftest, or prompt preview — and exactly one
   configured target. Stop and ask rather than guess an ambiguous target.
3. The order status → plan → independent plan approval → explicit user
   confirmation → scheduler assignment → independent audit → commit → push →
   deploy is immutable. Plan/audit approval means a correlated reviewer reply
   or reviewer-authored closing note carrying an explicit `APPROVE` token,
   fresh within the normalized harness TTLs — never a dispatch, a pane scrape,
   or a bare `done` status.
4. The orchestrator coordinates only: every Git mutation (commit, push,
   `--no-ff` merge, optional `--ff-only` alignment) is dispatched to and
   executed by the target's configured executor pane, inside the fixed Git
   floor (no force, no ref deletion, no history rewrite, no `checkout -B`).
5. Use the installed session-chat and session-scheduler skills for transport
   and ledger work; never pin marketplace cache paths and never create a
   parallel evidence log.

Report each gate's evidence honestly, including which confirmations are
conversational (user-stated) rather than machine-verified.
