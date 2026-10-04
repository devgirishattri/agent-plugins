---
name: graph
description: "Explicit-link knowledge graph over memory backlinks: neighbors, reverse links, orphans, components, or the whole graph as JSON/DOT/Mermaid. Read-only."
when_to_use: User asks what links to or from a memory, which memories are orphaned or clustered, or wants a graph/diagram of the memory links.
argument-hint: "[--store <path>] [neighbors <slug> | reverse <slug> | orphans | components | --format json|dot|mermaid]"
allowed-tools: Bash(bash:*)
---

## Instructions

`memory-backlinks.sh` is read-only. It never writes to the store. It builds an explicit-`[[slug]]`-link graph, not an inferred semantic graph.

- Determine which of the five forms below `$ARGUMENTS` requests.
- Run exactly **one** literal Bash segment. Use no `export`, `env`, or assignment prefix. Do not chain, pipe, or redirect.
- In all five forms, pass `--store <path>` only if the user supplied one.

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

Links inside fenced code blocks (backticks or tildes) and single-backtick inline code spans are not links.

## Exit codes

| Exit | Meaning | Next action |
|---|---|---|
| `0` | Success, including empty results. | Report the output (see Output). |
| `2` | A bad or unresolvable slug. For `neighbors` and `reverse`, stderr says `unknown slug: <arg>`. The slug does not resolve, either exactly or through the hyphen/underscore/case-normalized fallback. | Relay the message. Suggest `/knowledge:search <name>` to find the right slug. |
| `3` | The store could not be resolved. | Relay the stderr message. It suggests `/knowledge:init` when no store exists. |
| `4` | A store-integrity error: a slug collision, or a filename stem outside the safe `[A-Za-z0-9._-]` grammar. | Relay the message. Stop. This is a data problem in the store. Do not retry. |

## Output

Lead with the form you ran and the result count. Then show the rows.

- `neighbors <slug>`: rows `<in|out>\t<stem>`. In-edges come before out-edges. Each block is sorted by stem. A self-linking memory shows up as both an `in` row and an `out` row.
- `reverse <slug>`: one stem per line. These are the files that link to the slug.
- `orphans`: one stem per line. These are memories with no links in either direction.
- `components`: one line per weakly-connected cluster. Member stems are space-separated.
- whole graph `--format json`: `{"nodes":[{slug,type,status,tags}...],"edges":[{from,to}...]}`.
- whole graph `--format dot`: a Graphviz `digraph knowledge { ... }` block. If the user wants to render it, hand it over as a fenced ```dot``` block.
- whole graph `--format mermaid`: a `flowchart LR` block with positional `n<i>` node ids. Hand it back as a fenced ```mermaid``` block.

If stderr contains a `dangling: <n>` line, report that the store has `<n>` outgoing `[[links]]` that do not resolve to any file. The graph itself excludes them. Point the user at `/knowledge:lint` or `/knowledge:doctor` for the detailed per-link list. Do not enumerate them yourself.

$ARGUMENTS
