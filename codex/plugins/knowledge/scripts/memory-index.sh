#!/usr/bin/env bash
# memory-index.sh — MEMORY.md <-> authoritative-files reconciler (read-only).
# the MEMORY.md index grammar and recognized index row
# grammar". Detects the store's index style (flat/sectioned, or a degenerate
# style) and reconciles membership in both directions. Insertion (writing a
# new index row) happens via `memory-write.sh apply`'s staged-index leg
# (driven by the consolidate/promote skills) — this tool itself is
# report-only and never mutates MEMORY.md or any memory file.
#
# Usage: memory-index.sh [--store <path>]
# Output: one drift finding per stdout line, "DRIFT\t<kind>\t<file>" with
#   kind in missing-entry|missing-file|duplicate-membership|bad-target|style.
# Exit codes: 0 ok (read-only; DRIFT findings are informational, not errors);
#   2 usage; 3 store-resolution failure; 4 store-integrity error (slug
#   collision, or a style so ambiguous reconciliation cannot proceed safely).
# Supported platforms: macOS, Linux
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

store_arg=""
while [ $# -gt 0 ]; do
  case "$1" in
    --store)
      [ $# -ge 2 ] || { echo "ERROR: --store requires a value" >&2; exit 2; }
      store_arg="$2"
      shift 2
      ;;
    *)
      echo "ERROR: memory-index.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

store=$(km_resolve_store "$store_arg") || exit $?

drift() {
  printf 'DRIFT\t%s\t%s\n' "$1" "$2"
}

collision_count=0
while IFS=$'\t' read -r a b; do
  [ -n "$a" ] || continue
  drift "duplicate-membership" "$a (slug collision with $b)"
  collision_count=$((collision_count + 1))
done < <(km_slug_collision_pairs "$store" 2>/dev/null)
if [ "$collision_count" -gt 0 ]; then
  exit 4
fi

memory_file="$store/MEMORY.md"

# --- classify each line: row (bullet + markdown-link(s) ending .md),
# heading, blank, or prose. Track the FIRST link target per row (membership)
# and whether the row carries more than one link (multi-link, informational
# only for style detection).
_km_first_link_target() {
  # Extracts the target inside the FIRST "](...)" on the line.
  local line="$1" rest target
  rest="${line#*](}"
  [ "$rest" != "$line" ] || { printf ''; return 1; }
  target="${rest%%)*}"
  printf '%s\n' "$target"
}

_km_link_count_on_line() {
  local line="$1" n=0
  local rest="$line"
  while :; do
    case "$rest" in
      *"](")
        break
        ;;
    esac
    case "$rest" in
      *"]("*)
        n=$((n + 1))
        rest="${rest#*](}"
        rest="${rest#*)}"
        ;;
      *)
        break
        ;;
    esac
  done
  printf '%s\n' "$n"
}

declare -a row_targets=()
declare -a row_multilink=()
has_rows=0
has_headings=0
rows_under_heading=0
rows_without_heading=0
prose_line_count=0
seen_heading=0
total_lines=0

while IFS= read -r line || [ -n "$line" ]; do
  total_lines=$((total_lines + 1))
  case "$line" in
    "#"*)
      has_headings=1
      seen_heading=1
      continue
      ;;
    "")
      continue
      ;;
  esac
  case "$line" in
    "- ["*"]("*".md"*)
      target=$(_km_first_link_target "$line")
      row_targets+=("$target")
      lc=$(_km_link_count_on_line "$line")
      if [ "$lc" -gt 1 ]; then
        row_multilink+=("1")
      else
        row_multilink+=("0")
      fi
      has_rows=1
      if [ "$seen_heading" -eq 1 ]; then
        rows_under_heading=$((rows_under_heading + 1))
      else
        rows_without_heading=$((rows_without_heading + 1))
      fi
      ;;
    *)
      prose_line_count=$((prose_line_count + 1))
      ;;
  esac
done < "$memory_file"

# --- style classification / degenerate advisories ---
if [ "$has_rows" -eq 0 ]; then
  if [ "$total_lines" -gt 0 ]; then
    drift "style" "MEMORY.md is free prose with no index rows (propose an index skeleton)"
  fi
elif [ "$has_headings" -eq 1 ] && [ "$rows_without_heading" -gt 0 ] && [ "$rows_under_heading" -gt 0 ]; then
  # Some rows precede the first heading and some follow: neither purely flat
  # nor purely sectioned. Ambiguous — fail closed rather than guess.
  drift "style" "MEMORY.md mixes headed and un-headed index rows (ambiguous style)"
  exit 4
fi
if [ "$has_rows" -eq 1 ] && [ "$prose_line_count" -ge 2 ]; then
  drift "style" "MEMORY.md carries inline knowledge content alongside its index (propose extraction)"
fi

# --- validate row targets: bare basenames only ---
declare -a valid_targets=()
ri=0
while [ "$ri" -lt "${#row_targets[@]}" ]; do
  t="${row_targets[ri]}"
  case "$t" in
    */* | *..* | "")
      drift "bad-target" "$t"
      ;;
    *)
      valid_targets+=("$t")
      ;;
  esac
  ri=$((ri + 1))
done

# --- membership reconciliation (both directions) ---
declare -a auth_files=()
while IFS= read -r f; do
  [ -n "$f" ] || continue
  auth_files+=("$f")
done < <(km_authoritative_files "$store")

fi_=0
while [ "$fi_" -lt "${#auth_files[@]}" ]; do
  f="${auth_files[fi_]}"
  count=0
  ti=0
  while [ "$ti" -lt "${#valid_targets[@]}" ]; do
    [ "${valid_targets[ti]}" = "$f" ] && count=$((count + 1))
    ti=$((ti + 1))
  done
  if [ "$count" -eq 0 ]; then
    drift "missing-entry" "$f"
  elif [ "$count" -gt 1 ]; then
    drift "duplicate-membership" "$f"
  fi
  fi_=$((fi_ + 1))
done

ti=0
while [ "$ti" -lt "${#valid_targets[@]}" ]; do
  t="${valid_targets[ti]}"
  found=0
  fi_=0
  while [ "$fi_" -lt "${#auth_files[@]}" ]; do
    if [ "${auth_files[fi_]}" = "$t" ]; then
      found=1
      break
    fi
    fi_=$((fi_ + 1))
  done
  [ "$found" -eq 1 ] || drift "missing-file" "$t"
  ti=$((ti + 1))
done

while IFS= read -r symfile; do
  [ -n "$symfile" ] || continue
  drift "bad-target" "$symfile (symlinked .md excluded from authoritative set)"
done < <(km_symlinked_md_files "$store")

exit 0
