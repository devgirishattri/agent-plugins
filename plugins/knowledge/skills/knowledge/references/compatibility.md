# Knowledge downgrade compatibility

Read this before you install an older knowledge release over a newer one.

## Dismissed candidates (below 0.3.30)

Before you downgrade below knowledge 0.3.30, `restore` any dismissed candidate
that you still want pending. An older release leaves `.inbox/.dismissed/`
intact but ignores it. Its capture can re-queue identical content as pending,
and its listings do not show the archive. If both a pending and a dismissed
copy of the same id exist after you upgrade again, the writer refuses
`dismiss`/`restore` for that id (collision). Keep both copies for inspection
and resolve them explicitly. Never delete either copy automatically.

## Candidate attribution (below 0.5.0)

Every candidate written by 0.5.0 or later, manual ones too, carries
writer-assigned `origin_session` / `origin_pane`, and can carry `evidence`. A
pre-0.5.0 reader rejects those keys, so new-format inbox candidates are not
readable after a downgrade. Before you downgrade, consolidate, dismiss, or back
up the pending inbox. Candidates written before 0.5.0 stay valid under 0.5.0
with unchanged ids.
