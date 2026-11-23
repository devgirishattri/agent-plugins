---
name: design-sketch
description: "Sketch an ambiguous interface or choose between competing designs before planning; read-only. Use for \"how should we design this\", \"which approach should we take\", \"sketch the interface\". Not for simple or already-decided work."
when_to_use: "Use when a change adds an interface, command, schema or boundary whose shape is unsettled, or when two or more designs compete. Do not use for a preview of the tmux workspace lifecycle (workspace-plan), for dispatching a plan for review (workspace-orchestrator), for indirect-breakage analysis of an existing diff (blast-radius), or for a change with one obvious design."
---

# Design sketch

Produce a short, read-only sketch that helps choose an interface or a design.
This skill is advice. It does not implement, dispatch, approve, or plan.

This skill does not produce or preview a plan. Route these requests elsewhere:

- To preview what the tmux workspace lifecycle would start, use `workspace-plan`.
- To dispatch a plan for review, use `workspace-orchestrator`.
- To analyze indirect breakage in an existing diff, use `blast-radius`.

## Contract

- Work in any session. Require no `.agent-workspace/workspace.json`, no
  configured orchestrator, reviewer, or executor pane, and no helper script.
- Write no file, config, task, or message. Implement nothing. Dispatch nothing.
  Approve nothing.
- The sketch is advice. The owner of the affected tree, plugin, or component
  decides and implements.
- In a multi-pane workspace, route each owner's part to that owner. Do not
  present another owner's internals as settled.

## Keep simple work simple

Skip the sketch when the change has one obvious design, adds no interface or
boundary, or is already decided. Say so in one line and continue with the work.

Easy reversal alone is not a reason to skip. A reversible interface choice that
is still unresolved can get a short sketch. A sketch fits on about one screen.

## Steps

1. **Intent.** State the user outcome in your own words. Add the observed
   problem, the constraints, and the safety and authorization invariants that
   must hold. Separate evidence from assumption.
2. **Actual caller.** Name the real call site, command, or user action that will
   use the interface. Cite it as `path:line` where one exists. If no real caller
   exists, say so. An interface with no caller is speculative.
3. **Proposed interface.** Give the smallest signature, command, schema, or file
   shape. State inputs, outputs, and errors. State who owns and writes each piece
   of state. State compatibility with existing persisted data, the other
   provider, and other consumers.
4. **Simpler alternative.** Name the cheapest option. Consider reuse of what
   exists, removal, and doing nothing. State what each costs.
5. **Discriminating observation.** Name the cheapest observation whose result
   would change the decision. State which result favors which option. Run it only
   when it is read-only and within existing authority. Otherwise name it as the
   next step.
6. **Recommendation.** Recommend one option. List what stays open for the owner
   or the user.

## Output template

```text
Intent: <outcome; problem; constraints; invariants; evidence vs assumption>
Actual caller: <path:line or "none found">
Proposed interface: <shape; I/O/errors; state owner; compatibility>
Simpler alternative: <option; cost>
Discriminating observation: <check; result A favors X, result B favors Y>
Recommendation: <choice>; open: <owner or user decisions>
```

## Use in plan review

A plan sent for `PLAN REVIEW` can include the sketch. This is optional. See
[the lifecycle reference](../workspace-orchestrator/references/lifecycle.md).
The sketch adds no approval step and no evidence file. It does not replace the
configured reviewer's explicit approval.
