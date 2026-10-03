---
name: pr-status
description: Report structured GitHub pull-request blockers without merging or changing the PR. Use for a single readiness check, CI/review status, or an offline PR snapshot assessment.
---

# PR status

Resolve the installed plugin root from this skill's absolute source path, two
directories above SKILL.md. Run one literal Bash segment:

```bash
bash "<PLUGIN_ROOT>/scripts/pr-status.sh" --repo OWNER/NAME --pr NUMBER
```

Add `--expected-head <full-sha>` when the task is bound to a known revision.
For a supplied local snapshot, use `--snapshot <file>` instead of repo/pr.
Offline snapshots are untrusted observations, not current GitHub state.

The helper reads GitHub through `gh`, uses a fixed read-only GraphQL query for
paginated review threads, and checks that PR state did not change across the
observation. It does not comment, merge, push, retrigger CI, or poll indefinitely.
GitHub does not provide an atomic snapshot across these queries: a thread can
change after its page is read. Recheck at the existing merge preflight; this
observation is not a lock on PR state.
It needs existing GitHub authentication; never expose credentials or change
account settings to make a status check work. Under strict-v1 only the
orchestrator may use the live helper; other roles route the request through it.

Report the returned head and each blocker, pending check, or unknown. `ready`
(exit 0) requires a clean, mergeable, nondraft open PR, no unresolved threads,
no outstanding review requirement, and settled acceptable checks. `blocked`,
`waiting`, and `inconclusive` exit 1; unavailable queries or malformed input exit
2. Empty/missing checks, unknown forge state, or changed subject cannot become
ready. An outdated unresolved thread still requires disposition.

This is a conservative observation, not a proof of repository policy completeness
or authorization to merge. Use the existing reviewed Git lifecycle and user
authorization. A new commit or changed checks/reviews requires a fresh read.
Do not auto-retry failed writes or treat a status request as a babysitting loop.

Offline snapshot shape: `pr` is the JSON from `gh pr view` with fields `number`,
`url`, `headRefOid`, `baseRefOid`, `state`, `isDraft`, `mergeable`,
`mergeStateStatus`, `reviewDecision`, and `statusCheckRollup`; `threads` is the
complete array of objects containing `isResolved` and `isOutdated`;
`observed_head` is the head observed after collecting those threads. A caller-
authored snapshot cannot authenticate its own completeness or freshness.
