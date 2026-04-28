# Document Size and Splitting

A single document should cover a single coherent topic.

## When to Split

- The document exceeds ~300 lines and covers 2+ distinct subsystems (e.g., auth + payment in the same doc)
- The Table of Contents has 3+ top-level sections that could each stand alone
- Different audiences need different parts (e.g., API consumers vs. internal developers)

## When Long Is Fine

- API references with many endpoints — a single file is easier to search than scattered files (300-700 lines is normal)
- Feature docs where the lifecycle, database, and endpoints are tightly coupled — splitting would force the reader to jump between files

## How to Split

- Create one overview doc that links to the detail docs
- Each split doc should be self-contained — a reader should not need to read 3 other docs to understand it
- Name split docs by concept: `AUTH_OVERVIEW.md`, `AUTH_API_REFERENCE.md`, `AUTH_MOBILE.md` — never `AUTH_PART1.md` or lowercase names
- Update cross-references in all affected docs

## Auto-Split Check

After writing a document, scan its Table of Contents. If 3+ sections are each 80+ lines and serve different purposes, proactively suggest splitting to the user rather than delivering one massive file. Explain what the split would look like and let them decide.
