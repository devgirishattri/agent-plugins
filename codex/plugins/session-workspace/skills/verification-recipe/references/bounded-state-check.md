# Bounded state checks

Choose one property that matters to a caller. For example, a result from an
earlier assignment must leave the current assignment untouched. Identify
the implementation transitions, the actors, and the points where another
operation can intervene.

Use the smallest model that can expose the suspected ordering. Declare the
bounds, initial state, permitted events and assumptions. Explore each
reachable state within those bounds with the project's existing tooling.
Keep the property independent of the transition code. Record a failing
sequence in terms of caller-visible events.

Check the model itself. Change one transition in a copy while keeping the
property fixed. The altered model should produce a counterexample. Replay
that sequence against the real implementation in an isolated fixture. Check
the state before and after the delayed event, and exercise the matching
current event as the positive control. If the sequence cannot occur, revise
the model and rerun it. A bounded pass applies to the named property and
assumptions.

Record the source revision, relevant file digests for local changes, bounds,
coverage, counterexample and replay outcome. When a covered transition changes,
compare the model with the code and rerun both controls. Report whether a
failure came from model drift or changed product behavior.

The marketplace source checkout includes the scheduler pilot at
`scripts/test-scheduler-state-model.py`. Run `python3 -B scripts/test-scheduler-state-model.py`
from that checkout to exercise both providers. In another project, use its
own transitions, fixtures and verification permissions.
