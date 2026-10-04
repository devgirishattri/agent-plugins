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

The skill enforces these ground rules. This summary lets you refuse early:

1. Only the configured semantic **orchestrator** pane may run this workflow.
   Resolve the normalized plan first (`workspace-plan` with `--json` via the
   installed helper). Then require three facts:
   `.orchestration.active == true`, `.harness.active == true`, and a live
   `harness-status` identity MATCH.
2. Map `$ARGUMENTS` to exactly one workflow and exactly one configured target.
   The workflows are: status, plan review, executor dispatch, post-execution
   review, commit authorization, push authorization, deploy authorization,
   selftest, and prompt preview. Stop and ask rather than guess an ambiguous target.
3. The order is immutable: status → plan → independent plan approval →
   explicit user confirmation → scheduler assignment → independent audit →
   commit → push → deploy. Plan/audit approval means a correlated reviewer
   reply or a reviewer-authored closing note. It must carry an explicit
   `APPROVE` token and be fresh within the normalized harness TTLs. A
   dispatch, a pane scrape, or a bare `done` status is never approval.
4. The orchestrator coordinates only. It dispatches every Git mutation
   (commit, push, `--no-ff` merge, optional `--ff-only` alignment) to the
   target's configured executor pane. That pane executes it inside the fixed
   Git floor: no force, no ref deletion, no history rewrite, no `checkout -B`.
5. Use the installed session-chat and session-scheduler skills for transport
   and ledger work. Never pin marketplace cache paths. Never create a
   parallel evidence log.

Report each gate's evidence honestly. Say which confirmations are
conversational (user-stated) and which the machine verified.
