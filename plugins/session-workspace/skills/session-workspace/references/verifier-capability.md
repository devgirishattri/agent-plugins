# Owner-reviewed verifier guidance

This is design guidance for a separately reviewed execution capability. It does
not install a runner, add a configuration field, or authorize execution. Use an
existing authorized verification route when it meets the required bounds.
Otherwise keep the proposed capability inactive and report the missing support.

## Define the operation before granting execution

The project owner must review the verifier's behavior and its required access.
Record the actor, task, target source, expected evidence, and allowed side
effects. Keep execution separate from permission to publish, merge, push, or
deploy. A passing verifier supplies evidence; it grants none of those actions.

Bind the reviewed operation to:

- The verifier's full content digest and the relevant dependency contents,
  including imported scripts, interpreter/runtime, configuration and lockfiles.
- The exact executable and argument vector, including permitted input values.
  Do not substitute an unrestricted shell command or package-script name.
- The resolved working directory, input roots, output locations, and symlink
  policy. Define whether the source must be an immutable snapshot.
- The inherited environment, credential privileges, network destinations,
  resource limits, timeout, and cleanup ownership. Keep secrets out of records.
- The approval's scope, validity period or invalidation condition, revocation
  mechanism, and the owner-authorized execution route that enforces these bounds.

A tracked path can change after review. A digest identifies content but does
not prove its author, safety, or approval. Resolve dependencies before review;
unknown or mutable executable inputs cannot silently fall outside the binding.

## Preserve the boundary at execution

Require the execution route to compare the current operation with its reviewed
binding before it starts. An edited verifier, dependency, argument, working
directory or relevant environment invalidates that binding. Stop and obtain
the appropriate owner review; do not fall back to the old approval.

Hashing a mutable file and then executing its path leaves a substitution race.
Use a reviewed mechanism that executes the verified immutable contents and
bound dependencies. Until that mechanism exists, do not claim content-bound
execution. Retain the native sandbox and approval requirements throughout.

`read_paths` permits scoped reading; it does not permit executing a script from
that root. Existing package-script execution is not evidence that another
execution route is safe. A verifier copied into the checkout still needs its
own authorization and source/dependency review.

If the runner, binding, credentials or runtime is unavailable, report the
missing prerequisite. Do not widen permissions, replace inherited stores, or
run a different command. On timeout or ambiguous completion, inspect recorded
effects before retrying. Revoke the capability when its reviewed bounds change.

## Evidence required before adoption

Exercise the real proposed route with a valid control and each refusal case:
changed script or dependency, wrong actor, arguments or cwd, altered environment,
expired or revoked approval, symlink substitution, missing runtime and timeout.
Verify that refusal precedes execution, and that cleanup touches only owned
fixtures and verified owned process IDs. Preserve logs outside cleanup scope.

Record the source and dependency digests, approved operation, runtime/platform,
observed exit status, actual effects, and retained artifacts. Label unrun checks
and unknown outcomes. These requirements are not evidence that this plugin has
implemented or tested such a runner.

For current recipe authoring and evidence handling, use
[verification-recipe](../../verification-recipe/SKILL.md). Existing scheduler
contracts remain governed by
[task-contract](../../../../session-scheduler/skills/task-contract/SKILL.md);
this guidance neither replaces their admission checks nor adds an execution
grant to the harness.
