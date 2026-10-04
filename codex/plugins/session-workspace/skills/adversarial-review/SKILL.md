---
name: adversarial-review
description: Run an optional, budgeted independent review that tries to break a specific diff or subject and records an evidence-based disposition for every finding. Use when a risky change warrants a second, adversarial pass beyond the configured reviewer, or when explicitly asked for an adversarial review.
---

# Adversarial review

An optional extra pass over an exact subject. It adds findings and evidence; it
does not replace the configured independent reviewer, approve a change, or
authorize commit, push, merge, or deployment.

## Bind the subject and budget

1. Name the exact subject: base/head revisions or a diff digest, uncommitted
   paths, the review packet or task it belongs to, and the acceptance criteria.
   If the subject changes during review, findings against the old subject are
   stale; re-bind or label them.
2. Set the budget before starting: number of reviewers or passes, wall time, and
   any model spend. Use only runtimes and models already configured for this
   project or available to the caller. Do not add a model dependency, acquire
   credentials, or run paid evaluations unless the user gives an explicit
   request and ceiling.
   When the budget runs out, stop and list what was not reviewed.
3. Keep reviewers independent: give each the subject and acceptance criteria,
   not the author's conclusions or earlier findings. A reviewer never reviews
   its own authored change. Respect role restrictions. A read-only reviewer
   routes any execution it is not permitted to perform to the configured executor.

## Attack the change

For each claim the change makes (correctness, safety, compatibility, cleanup),
look for a concrete counterexample. Check these cases:

- hostile or malformed input
- concurrent actors
- partial failure and retry
- stale or mixed versions
- other providers
- persisted data
- privilege or path boundaries

Prefer the cheapest check that can discriminate. Read the code path, run an
existing test, or add a focused isolated check within existing authorization.
A negative check needs a positive control. Never use live stores. Never loosen
a harness to complete a review.

Each finding states severity, location, failure mechanism, a concrete scenario,
and evidence type: source inspection, executed isolated test, or observed
runtime behavior. Speculation is labeled as such.

## Record dispositions

Every finding ends with exactly one disposition, each backed by evidence:

- **fixed** — the fix and its verification are bound to the new subject; the
  original finding's reproduction now passes or fails as intended.
- **rejected** — evidence shows the scenario cannot occur or is out of scope;
  "the author disagrees" is not evidence.
- **deferred** — an existing tracker reference or a proposed entry with an owner
  and acceptance criteria. State who accepted residual risk, or that acceptance
  is pending. File or modify a ticket only when that write is authorized.
- **unverified** — the discriminating check was not run; name it.

## Authority

Agreement between models, a majority vote, or the absence of findings is not
approval and not proof of correctness. Disagreement is resolved by evidence,
not by count. The configured reviewer, existing approval gates, and explicit
user confirmation remain authoritative. Attach the report, or a reference to
it, to the existing review packet or scheduler note; do not create another
approval ledger.
