---
description: Coordinate the schema-v4 reviewed Git lifecycle (status/plan/dispatch/review/commit/push/deploy) across configured executor/reviewer panes
argument-hint: "<intent, e.g. 'status', 'plan review for <target>: <task>', 'authorize push for <target>'>"
---

## Instructions

1. Load and follow the `session-workspace:workspace-orchestrator` skill for the
   user's intent in `$ARGUMENTS`. It is the complete, provider-neutral contract
   for this command. Do not improvise a lifecycle or weaken, reorder, skip, or
   duplicate its gates.

2. Refuse early unless the current pane is the configured semantic
   orchestrator, the normalized schema-v4 plan reports active orchestration and
   harness state, and live harness identity matches.

3. Map the request to exactly one workflow and one configured target. Plan and
   audit approval require fresh, explicit `APPROVE` evidence from the configured
   reviewer; dispatch, pane output, or a bare scheduler `done` state is not an
   approval.

4. Coordinate only. Every Git mutation is separately authorized, dispatched
   to, and executed by the target executor within the skill's fixed Git floor.
   Use installed session-chat and session-scheduler capabilities, never pinned
   cache paths or a parallel evidence log.

5. Report machine-verifiable and conversational gates separately and honestly.
