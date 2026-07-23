---
description: "Explicit-link knowledge graph over memory backlinks (neighbors, reverse links, orphans, components, whole-graph JSON/DOT/Mermaid)"
argument-hint: "[--store <path>] [neighbors <slug> | reverse <slug> | orphans | components | --format json|dot|mermaid]"
allowed-tools: Bash(bash:*)
---

## Instructions

`memory-backlinks.sh` is read-only: it never writes to the store. This is an explicit-`[[slug]]`-link graph, not an inferred semantic graph. Determine which of the five forms below `$ARGUMENTS` requests, then run exactly **one** literal Bash segment (no `export`/`env`/assignment prefix, no chaining/piping/redirection) — pass `--store <path>` only if the user supplied one, in all five forms:

1. **Neighbors of a slug** — `$ARGUMENTS` names a slug and asks for its links/neighbors:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] neighbors <slug>
   ```
2. **Reverse links** — `$ARGUMENTS` asks what links TO a slug:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] reverse <slug>
   ```
3. **Orphans** — `$ARGUMENTS` asks for memories with no in/out links:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] orphans
   ```
4. **Components** — `$ARGUMENTS` asks for weakly-connected clusters:
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] components
   ```
5. **Whole graph** (default when `$ARGUMENTS` names none of the above, or explicitly asks for the full graph / a DOT or Mermaid render):
   ```
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/memory-backlinks.sh" [--store <path>] graph [--format json|dot|mermaid]
   ```
   Omit `--format` (defaults to `json`) unless the user asked for a DOT (Graphviz) or Mermaid diagram.

Exit codes: `0` success (including empty results); `2` a bad/unresolvable slug — for `neighbors`/`reverse` this means stderr said `unknown slug: <arg>` (the slug doesn't resolve, exactly nor via the hyphen/underscore/case-normalized fallback); relay it and suggest `/knowledge:search <name>` to find the right slug. `3` the store could not be resolved — relay the stderr message (suggests `/knowledge:init` when none exists). `4` a store-integrity error (slug collision or a filename stem outside the safe `[A-Za-z0-9._-]` grammar) — relay and stop; this is a data problem in the store, not something to retry.

## Output

- `neighbors <slug>`: rows `<in|out>\t<stem>` — in-edges before out-edges, each block sorted by stem. A self-linking memory shows up as both an `in` and an `out` row.
- `reverse <slug>`: one stem per line — the files that link to it.
- `orphans`: one stem per line — memories with no links in either direction.
- `components`: one line per weakly-connected cluster, member stems space-separated.
- whole graph `--format json`: `{"nodes":[{slug,type,status,tags}...],"edges":[{from,to}...]}`. `--format dot`: a Graphviz `digraph knowledge { ... }` block — hand it to the user as a fenced ```dot``` block if they want to render it. `--format mermaid`: a `flowchart LR` block with positional `n<i>` node ids — hand it back as a fenced ```mermaid``` block.

If stderr contains a `dangling: <n>` line, mention that the store has `<n>` outgoing `[[links]]` that don't resolve to any file (excluded from the graph itself) — point at `/knowledge:lint` or `/knowledge:doctor` for the detailed per-link list rather than trying to enumerate them yourself.

$ARGUMENTS
