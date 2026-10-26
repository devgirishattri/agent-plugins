# Knowledge downgrade compatibility

Read this before you install an older knowledge release over a newer one.

## Dismissed candidates (below 0.3.30)

Downgrading below knowledge 0.3.30 leaves `.inbox/.dismissed/`
intact but no longer consulted: an older capture can re-queue identical
content as pending, and older listings ignore the archive. Nothing in the
archive is lost. Restore wanted candidates before downgrading. If an older
capture creates both pending and archived copies, the upgraded writer refuses
the collision. Preserve both for inspection and an explicitly approved
resolution. Never delete either copy automatically or attempt restore/re-dismiss blindly.

## Candidate attribution (below 0.5.0)

Every candidate written by 0.5.0 or later, including manual candidates,
carries writer-assigned `origin_session` / `origin_pane`, and can carry
`evidence`. A pre-0.5.0 reader rejects those keys. Therefore new-format inbox
candidates are NOT transparently readable after a downgrade. Before you
downgrade, consolidate, dismiss, or back up the pending inbox. Candidates written
before 0.5.0 stay valid under 0.5.0 with unchanged ids.
