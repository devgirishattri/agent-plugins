# Bounded state check

Use this procedure from the verification recipe when correctness depends on the
order of events. Examples are concurrent actors, retries, uncertain delivery,
and late results. Skip it for single-actor, deterministic behavior.

## Purpose and limits

The check explores every ordering of a small set of events within stated bounds.
It tests one invariant. It is not a proof about the implementation. It is not an
approval. It is not a new gate.

## 1. Choose the question

State one safety invariant in observable terms. Check one invariant per model.

Synthetic example: "A result from an obsolete assignment generation never
changes the task."

## 2. Build the smallest model

- Use a few state variables.
- Write one action for each real operation, for example assign, uncertain
  delivery, reconcile, and late result.
- State the bounds: actors, generations, steps, and retries.
- Keep the model deterministic. Use no clocks, randomness, or network.
- Enumerate all orderings within the bounds. Keep a visited set.
- Count the states and the transitions.

A search that explored zero states or zero transitions cannot pass.

## 3. Map the model to the code

Keep a small table. Give each model action and guard one row:

| Model action or guard | Code (path, function) | Revision read |
|---|---|---|
| `late_result` guard | `src/queue.py`, `accept_result` | `abc1234` |

Record the revision with the evidence. When mapped code changes, the model is
stale. Re-read the model against the code before you reuse its result.

When a check fails, classify the cause:

- **Model drift:** the code changed or the model misread it. Correct the model.
- **Harness gap:** the fixture or driver cannot reach the step. Correct the harness.
- **Product bug:** the real code violates the invariant. Report it.

Edit only the model and recipe scope. Never change product code to make the
check pass.

## 4. Replay the shortest failing trace

A violation found in the model is a hypothesis. Replay the shortest failing
sequence against the real implementation. Use public entry points in an
isolated fixture.

- If the real code cannot perform a step, the trace is infeasible. Correct the
  model. Do not report a product bug.
- If the real code performs every step and breaks the invariant, report a
  product bug with the trace.
- Never replay a mutating action against live stores.

## 5. Run both controls

- **Mutant control:** in a copy of the model, remove one guard, for example the
  generation guard. Confirm the search reports a violation of the same
  invariant. This shows the search can detect what it claims.
- **Legitimate control:** run a valid sequence, for example a result from the
  current generation. Both the model and the real implementation must accept
  it. This prevents a check that rejects everything from passing.

A check without both controls remains a draft.

## 6. Record the evidence and the result

Record these items:

- the bounds and the invariant text;
- state and transition counts;
- the mutant result and the replay results;
- the code revision and its dirty state;
- the command, its exit status, and the platform.

Report passed, failed, blocked, or inconclusive. State what the bounds do not
cover. Link the evidence from the existing review note or handoff. Create no
other ledger.

## 7. Choose dependencies

Default to the project's existing test tooling. On your own initiative, do not
install a model checker, add a network dependency, or add a diagram tool.
Consider a separate checker or a diagram only when the project already uses one
or the user asks. Do so only after the small pilot shows coverage worth
maintaining.

## 8. Isolate and clean up

Follow the recipe's cleanup rules. Create fixtures in this run only. Never use
inherited live stores. Remove only what this run created.

## Source-checkout pilot

In the agent-plugins source checkout, session-scheduler owns the first model:
`scripts/test-scheduler-state-model.py`, relative to the checkout root. The
plugin does not install it. Run `python3 -B scripts/test-scheduler-state-model.py`
at the checkout root. Read the script for its bounds and coverage. Before you maintain it, compare its result with the existing
ambiguous-delivery and late-completion scheduler tests.
