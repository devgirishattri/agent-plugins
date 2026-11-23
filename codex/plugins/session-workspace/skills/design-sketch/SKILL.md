---
name: design-sketch
description: Sketch a proposed interface or compare competing designs before implementation. Use when caller needs or an unresolved design choice could change the plan.
---

# Design sketch

Start from an actual caller and the outcome it needs. Show the smallest
useful interface with an example input and observable result. Trace who
owns the state, how an existing caller would migrate, or what failure it
would observe when those details distinguish the designs.

Compare the proposal with the simplest viable alternative, including using
the existing interface. State the tradeoff that matters to this caller.
Name the observation that would change the recommendation and the smallest
experiment that could supply it. Mark an unrun experiment as proposed.
Leave product choices that evidence cannot settle with the user.

Return a short design in the conversation or as part of the requested plan
review. This read-only workflow works without a configured workspace. A
routine edit with an established interface can proceed directly. A sketch
alone grants no authority to dispatch work or approve a plan.
