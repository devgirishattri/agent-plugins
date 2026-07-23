#!/usr/bin/env bash
# list-contexts.sh — List context snapshots for the current project
# Usage: list-contexts.sh
#
# Phase E (KNOWLEDGE_PLUGIN_SPEC.md "Promotion + handoff lifecycle"): a
# snapshot carrying `kind: handoff` frontmatter gets exactly one appended
# column, `\thandoff\t<expires>`. Plain-snapshot rows are byte-unchanged —
# proven by test-promotion.sh's before/after comparison against this exact
# pre-Phase-E format.
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

SNAPSHOTS_DIR="$(get_contexts_dir)" || exit 1
HISTORY_DIR="$SNAPSHOTS_DIR/.history"

if [ ! -d "$SNAPSHOTS_DIR" ] || [ -z "$(ls "$SNAPSHOTS_DIR"/*.md 2>/dev/null)" ]; then
  echo "No context snapshots found for this project. Use /context-generate to create one."
  exit 0
fi

# _ctx_fm_get <file> <key> -> minimal top-level frontmatter scalar getter.
# Same minimal shape as doctor.sh's _kd_fm_get / save-context.sh's copy of it
# (top-level, non-indented "key: value" lines only, between a leading and
# trailing "---" fence) — duplicated rather than shared via lib.sh, which
# stays memory/context mechanics only, not frontmatter parsing.
_ctx_fm_get() {
  local file="$1" key="$2" first_line line lineno=0 k v
  IFS= read -r first_line < "$file" 2>/dev/null || return 1
  [ "$first_line" = "---" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ "$lineno" -eq 1 ] && continue
    [ "$line" = "---" ] && return 1
    case "$line" in
      " "*|$'\t'*) continue ;;
      *:*)
        k="${line%%:*}"
        v="${line#*:}"
        while [ "${v:0:1}" = " " ]; do v="${v:1}"; done
        v="${v%\"}"
        v="${v#\"}"
        if [ "$k" = "$key" ]; then
          printf '%s\n' "$v"
          return 0
        fi
        ;;
    esac
  done < "$file"
  return 1
}

for snapshot in "$SNAPSHOTS_DIR"/*.md; do
  [ -f "$snapshot" ] || continue
  name=$(basename "$snapshot" .md)
  size=$(wc -l < "$snapshot" | tr -d ' ')
  if [ "$(uname)" = "Darwin" ]; then
    modified=$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$snapshot" 2>/dev/null)
  else
    modified=$(stat -c '%y' "$snapshot" 2>/dev/null | cut -d'.' -f1)
  fi
  versions=$(ls -1 "$HISTORY_DIR/${name}."*.md 2>/dev/null | wc -l | tr -d ' ')
  row=$(printf '%s\t%s lines\t%s\t%s versions' "$name" "$size" "$modified" "$versions")
  kind=$(_ctx_fm_get "$snapshot" kind 2>/dev/null) || kind=""
  if [ "$kind" = "handoff" ]; then
    expires=$(_ctx_fm_get "$snapshot" expires 2>/dev/null) || expires=""
    printf '%s\thandoff\t%s\n' "$row" "$expires"
  else
    printf '%s\n' "$row"
  fi
done
