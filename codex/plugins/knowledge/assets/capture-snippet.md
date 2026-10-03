<!-- knowledge:capture:start -->
When a durable, reusable learning surfaces mid-task — a fixed gotcha, a
confirmed convention, a decision and its rationale, a preference the user
stated — capture it immediately with `$knowledge:remember <what>` (Codex)
or `/knowledge:remember <what>` (Claude). It is low-friction and only queues
a candidate in the inbox; nothing durable is written yet. At the end of a
working session, or whenever the inbox is non-empty, run
`/knowledge:consolidate` (Claude) or `$knowledge:consolidate` (Codex) to
review the candidates into the durable store. Verified, reusable lessons may
also be queued implicitly as inbox-only candidates with `evidence:`; that never
promotes anything, and `consolidate` is never run automatically. To wrap up a
session (docs, memory, configured tickets, context) in one reviewed batch, ask
for `distill`. Never hand-write memory files in the store — let the
consolidate/promote flow own every durable write.
<!-- knowledge:capture:end -->
