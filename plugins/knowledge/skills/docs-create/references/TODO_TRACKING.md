# TODO and Issue Tracking

Every project's `docs/` directory should keep two dedicated tracker files. These files are the **only** place to record TODOs and issues. Never embed them in documentation files. This keeps docs clean: they describe what *is*, not what is *planned*. It also gives developers a single place to check for outstanding work.

## `docs/TODO.md`

Captures planned improvements, missing features, and future work discovered during documentation or development.

```
# TODO

## [Feature/Module Name]

- [ ] Description of what needs to be done
  - Context: discovered while documenting [DOC_NAME.md]
  - Priority: high | medium | low

- [ ] Another item
  - Context: [source]
  - Priority: [level]
```

## `docs/ISSUES.md`

Captures bugs, inconsistencies, security concerns, and technical debt discovered during documentation or development.

```
# Known Issues

## [Feature/Module Name]

- [ ] Description of the issue
  - Impact: what breaks or degrades
  - Discovered: while documenting [DOC_NAME.md]
  - Severity: critical | high | medium | low

- [ ] Another issue
  - Impact: [description]
  - Severity: [level]
```

## When Writing Docs

If you discover a TODO or issue while documenting a feature, add it to the appropriate tracker file (`docs/TODO.md` or `docs/ISSUES.md`). Do not add it to the documentation itself. Create the tracker files if they do not exist yet.

## When Resolving Items

When a TODO or issue is resolved:
1. Mark the item as done (`- [x]`) or remove it from the tracker file
2. Update the original documentation that the item relates to. The doc can need new sections, corrected flows, or updated references to reflect the resolution.
3. If the changes were significant, update the Date in the doc's metadata.

This two-way sync keeps both the tracker and the documentation accurate. A resolved issue that the doc does not reflect misleads readers. A doc update that does not clear the tracker creates clutter.
