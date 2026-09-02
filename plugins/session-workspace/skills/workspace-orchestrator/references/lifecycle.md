# Reviewed Git Lifecycle

The normalized `workspace-plan --json` target is authoritative throughout a
workflow. Re-run status before each mutating authorization. If its coordinates
or the workspace config changed, discard prior evidence and restart at plan
review.

## Shared packet

Every plan, assignment, audit, and authorization packet includes:

```text
WHAT: exact requested outcome
WHY: user/business reason
WHERE: target id, resolved cwd, and concrete components
WHEN: timing/deadline or n/a
PAST: diagnostics, prior attempts, source verification, and reviewer conditions or n/a
```

Multiline packets use file-backed dispatch or scheduler assignment. A delivered
or durably queued packet is successful and must not be resent merely because a
reply is pending.

## Status

1. Use session-chat pane discovery and health to verify the configured
   orchestrator, target executor, and target reviewer are live and not locked.
2. Verify harness status/identity and run harness doctor when identity or hook
   health is uncertain.
3. Inspect the root read-only. Inspect the target checkout read-only from the
   orchestrator using literal Git queries; do not mutate it or change into it.
4. Report current branch, dirty state, HEAD, existing local/remote-ref
   divergence, work-to-release and release-to-work counts, and active scheduler
   tasks.
5. Halt downstream actions on missing panes, dirty/incorrect branch state not
   expected by that stage, release ahead of work, or stale/ambiguous evidence.

These checks use existing refs only. An executor preflight refreshes remote refs
before push or deploy.

## Plan review

1. Run status and read the target repository's applicable `AGENTS.md` files.
2. File-dispatch a read-only `PLAN REVIEW` to the configured reviewer. Include
   the shared packet, complete plan, files, acceptance criteria, verification,
   risks, and exclusions.
3. Wait for its correlated reply. Approval requires an explicit `APPROVE` token
   plus any conditions. `task-done`, delivery, silence, or inferred sentiment
   is insufficient.
4. Record no extra evidence file. The correlated session-chat record is the
   evidence and expires after `plan_review_ttl_minutes`.
5. Stop after approval unless the user explicitly confirms executor dispatch.

## Executor dispatch and audit

1. Re-run status; verify the exact correlated plan approval is fresh; obtain
   explicit user confirmation.
2. Create one scheduler task at stage `execute`, with a workflow id and the
   configured reviewer. Assign it to the configured executor with automatic
   context.
3. The assignment includes the shared packet, approved plan and conditions,
   repository instructions, scope, acceptance criteria, tests, and:

```text
Stay inside the configured target cwd.
Do not commit, push, merge, or deploy without a separate authorization.
When implementation and tests finish, call task-review so the configured reviewer receives the audit packet.
Report exact changed paths and verification results.
```

4. The executor calls task-review; the configured reviewer audits independently
   and closes with `task-done "APPROVE: ..."` or rejects with `task-block`.
5. Before commit authorization, verify reviewer authorship, task identity,
   reviewed diff/SHA, timestamp freshness within `audit_ttl_minutes`, and an
   explicit `APPROVE` token in the closing note or correlated reply. A `done`
   status alone proves closure, not a clean verdict.

## Commit

Requires a user-explicit commit request and fresh audit approval.

Dispatch the executor to verify the work branch and pending reviewed changes,
then commit only that reviewed scope using repository conventions. The packet
explicitly forbids push, release checkout, merge, and deploy. Require the commit
SHA, final status, and recent log. Commit authorization never implies push.

## Push

Requires a separate user-explicit push request after commit.

1. Dispatch a read-only executor preflight that refreshes the configured remote
   and proves: current branch is the work branch, tree is clean, local work is
   ahead of `<remote>/<work>`, and local work is not behind it.
2. Show the exact outgoing commits and obtain final user confirmation.
3. Dispatch only a normal `git push <remote> <work_branch>`. Require the pushed
   SHA and empty post-push ahead/behind output.

Never force, use a leading `+`, delete a ref, bypass hooks, or infer deploy
authority.

## Deploy: `merge-no-ff-v1`

Requires a separate user-explicit deploy request. Every command runs in the
executor pane.

The read-only executor preflight refreshes the configured remote and proves all
six gates:

1. work and release branches exist locally and at the configured remote;
2. release-to-work contains at least one commit to ship;
3. work-to-release is empty (release is not ahead of work);
4. local work exactly equals its remote ref;
5. local release exactly equals its remote ref;
6. the working tree is clean.

Show the exact commits and obtain final user confirmation. The executor may
then push the work ref normally, check out release without `-B`, update it only
by fast-forward, merge work into release with `--no-ff`, and push release
normally. It returns to work afterwards.

When `align_work_after_release` is true, the executor may fast-forward work to
the exact newly-created release merge commit and push work normally. It must use
`--ff-only`; if that is impossible, stop and report without merge, rebase,
reset, or force. When false, report the expected release-ahead-of-work state.

The fixed Git floor permits only fetch/status/read checks, commit on work,
normal pushes of the configured work/release refs, the reviewed `--no-ff`
work-to-release merge, and optional `--ff-only` alignment. Never force, delete a
ref, rewrite history, use `checkout -B` on release, or bypass verification.

## Selftest and prompt preview

Selftest is read-only: assert schema/normalized plan, workspace doctor,
harness-status identity, harness doctor, configured pane health, and ledger
readability. It does not run live denial canaries or repair state.

Prompt preview formats the selected workflow packet with target, required
evidence, acceptance criteria, verification, reply contract, and prohibitions,
labels it `UNSENT`, and performs no dispatch or ledger write.

## Evidence taxonomy

Machine-verifiable: validated plan coordinates, pane identity/health, correlated
review replies, scheduler state/history/authorship, TTL calculations, and Git
preflight output. Conversational only: the user's dispatch, commit, push, and
deploy confirmations. Never claim the harness enforces those confirmations.
