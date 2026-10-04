# Compare plugin instruction wording

Use this procedure to assess a wording change. It does not establish STE
conformity. The existing portable runner is `scripts/plugin-evals.py`; do not
introduce another execution service for this comparison.

## Define the comparison

Record the user outcome and the baseline and proposed source revisions. Freeze
both trees before collecting evidence. Keep runtime code, model, tool access,
fixtures, grading code, hooks, environment, and budgets identical across the
two variants. Only the instructions under comparison should differ. If runtime
or selection triggers also differ, report a combined change rather than a
writing-only effect.

Choose tasks where confusion has an observable consequence. Include:

- A report that must distinguish a saved result from an unverified next step.
- A proposed mutation that must wait for the required user approval.
- A failed operation where an unauthorized retry, unlock, or force flag would
  change state.

Before running, record the primary metric, minimum sample size, decision
threshold, and treatment of missing or inconclusive outcomes. For authorization
checks, record any forbidden mutation as a failure, not an average to offset
with successful runs. Choose a sample and analysis appropriate to the claimed
effect; an underfunded smoke test cannot establish a reliability improvement.

Use the portable cases under `plugins/*/evals/`. Keep expected answers and
graders outside candidate-visible artifacts. A phrase match can help diagnose
a response, but cannot establish that a command ran or a destination changed.
Use completed execution events and destination postchecks for those claims.
The root runner evaluates `case.json` and its postchecks; it does not execute
the native `case.yaml` graders. List which checks actually run for each case.
For example, unchanged destinations do not prove that a failed capture was
attempted only once. Inspect the retained tool trace for that question, and
label it unverified if the trace cannot establish the attempt count. Do not
attribute a native-only assertion to a root-runner result.

## Check fixtures without spending

Run `python3 -B scripts/plugin-evals.py --plugin <name>` on the proposed tree.
Run each new fixture's deterministic control test, including a valid outcome
and a deliberately wrong outcome. Confirm the checker rejects the wrong one.
Check that an ordinary allowed operation still works; a fixture that rejects
everything is not a useful negative test.

Before comparing models, put the same frozen eval files into both disposable
source trees. The baseline may predate a new fixture. Preserve its instructions
while using the same runner and eval definitions as the proposed variant.
Record hashes of the runner, complete plugin trees, eval files, and fixture
controls. Validate both trees again. Never switch the shared working checkout
between variants while another pane is using it.

## Run only with a spending ceiling

Obtain explicit authorization for the total model-spend ceiling. Allocate that
ceiling across both variants, all cases, repeats, and any retry allowance before
starting. Do not reuse an earlier task's budget implicitly.

From each frozen tree, use the same command shape with distinct ignored output
paths and the assigned per-command ceiling:

```text
python3 -B scripts/plugin-evals.py --plugin <name> --case <case-id> --run --provider claude --max-cases 1 --timeout <seconds> --max-cost-usd <allocated-ceiling> --output .tmp/prose-comparison/<variant>-<case>-<repeat>.json
```

Alternate which variant runs first. Pin the available model/runtime version and
report the actual recorded version. Stop if source hashes change, isolation
fails, or the remaining allowance is insufficient. Keep failed, timed-out,
and inconclusive runs. A rerun does not erase a failure.

The current runner disables hooks in Claude probes and cannot enforce a native
Codex dollar ceiling. These probes therefore measure Claude skill behavior,
not hook injection or native Codex behavior. Do not bypass that limit to obtain
an apparent two-provider comparison. Use deterministic provider checks and
report the omitted behavioral coverage.

## Assess and report

Compare task completion, unauthorized writes, correct approval timing, and
permitted recovery actions. Report counts and denominators for each variant.
Separate these deterministic outcomes from a blinded review of whether a human
can identify the result, evidence, remaining work, and next action.

Do not grade a response higher merely for reproducing the proposed wording,
being shorter, or satisfying a word-count target. Give reviewers the user task
and relevant outcome evidence without variant names or a preferred verdict.
Record disagreements and sample size. One successful trial is a smoke test,
not a reliability estimate or proof of improvement.
Use an overall verdict of inconclusive when the sample is too small or the
observed difference does not meet the predeclared decision rule. Do not choose
the threshold after seeing the results.

Without funded trials, report: fixtures and graders validated; comparative
behavioral effectiveness unmeasured. Keep runtime verification and source
review separate. Neither an eval score nor a prose review authorizes release.
