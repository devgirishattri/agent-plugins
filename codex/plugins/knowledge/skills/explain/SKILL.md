---
name: explain
description: Explain how project code works or why a design was chosen. Trace a call, identify which component owns a decision, or teach a subsystem from source and decision history.
---

# Explain

Answer the question in the conversation. For current behavior, start at the
entry point the caller actually uses. Follow one representative input to its
observable result. Name the component that owns each important decision or
state change, and link to the definitions that show it.

For a question about intent, look for the decision in scoped project docs or
the commit that introduced the behavior. Attribute an explanation to its
source. When the record is silent, say so. Label any explanation you infer
from the implementation. If the documented design and current code diverge,
describe both with their revisions when available.

For teaching, start with the smallest complete example and add detail at the
point the reader needs it. Read only the relevant project material. This
workflow is read-only. A request to document or change the system has its
own authoring workflow.
