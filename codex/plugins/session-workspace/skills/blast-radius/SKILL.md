---
name: blast-radius
description: Review a proposed change for indirect breakage and test the assumptions that make it safe. Use for impact analysis, risky diffs, or an explicit blast-radius review.
---

# Blast-radius review

Produce a report against an exact diff or revision. This skill does not edit
product code, close scheduler tasks, or authorize commit, push, or deployment.

1. Establish intended behavior, changed paths, base/head revisions, and any
   uncommitted changes. Separate observed facts from assumptions. If the target
   changes during review, invalidate affected findings and identify the new scope.
2. Trace the changed contract beyond direct callers: persisted data, wire formats,
   other providers or languages, installed versions, configuration, lifecycle
   ordering, concurrent actors, and retry/partial-failure behavior. Follow only
   relevant boundaries; a grep result alone does not establish compatibility.
3. Name the concrete assumptions on which safety depends. For each important
   assumption, identify a counterexample and the cheapest useful check. Prefer
   existing tests and real public entry points. A negative check needs a positive
   control so a broken environment cannot masquerade as correct rejection.
4. Run checks only within the caller's existing role, permitted paths, and task
   authorization. A read-only reviewer may inspect evidence or run permitted
   isolated checks; it must route prohibited execution to the configured executor.
   Never loosen a harness, use live stores, or acquire credentials to complete a
   review. Unavailable checks remain explicitly unverified.
5. Report findings by severity with the failure mechanism, source location,
   affected consumer, and evidence. Distinguish source inspection, an executed
   isolated test, and observed runtime behavior. List cleared risks with their
   basis and unresolved assumptions with the next discriminating check.

Attach the report or its reference to the existing review packet. Preserve the
configured independent reviewer and current approval requirements. Agreement
between models, absence of findings, and a task's `done` state are not proof of
correctness. Do not create another approval ledger.

When reviewing the agent-plugins source repository, include provider parity, launch-inherited stores, packaged
helpers, skill/script argument compatibility, and mixed-version behavior when
the diff touches those contracts. Do not run unrelated suites just to enlarge
the report.
