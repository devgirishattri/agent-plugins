#!/usr/bin/env bash
# memory-lint.sh — two-tier memory-store schema linter (read-only).
# the memory schema (v1 canonical + legacy compatibility
# mode)". Validates canonical v1 files (required-field presence + value
# shapes) and gives field-specific migration advice for legacy files (files
# without schema_version); never mutates anything.
#
# Usage: memory-lint.sh [--store <path>]
# Output: one finding per stdout line, "<LEVEL>\t<file>\t<message>" with
#   LEVEL in ERROR|ADVISORY|WARN.
# Exit codes: 0 ok (no ERROR finding); 2 usage; 3 store-resolution failure
#   (including fail-closed ambiguity); 4 store-integrity error (collision).
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
      echo "ERROR: memory-lint.sh: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

store=$(km_resolve_store "$store_arg") || exit $?

HAS_ERROR=0
emit() {
  local level="$1" file="$2" msg="$3"
  printf '%s\t%s\t%s\n' "$level" "$file" "$msg"
  [ "$level" = "ERROR" ] && HAS_ERROR=1
  return 0
}

KM_LINT_ENUM_TYPE="user feedback project reference"
KM_LINT_ENUM_STATUS="active stale superseded archived"
KM_LINT_ENUM_CONFIDENCE="low medium high"
_km_lint_in_list() {
  local needle="$1" hay="$2" w
  for w in $hay; do [ "$w" = "$needle" ] && return 0; done
  return 1
}

_km_lint_is_date() {
  [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

_km_lint_is_kebab() {
  [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# --- Frontmatter access (lenient — reads legacy shapes too). Sets:
#   KML_KEYS[] (top-level key names, in file order, dotted for one-level
#   nested mappings e.g. metadata.type), KML_VALS[] (parallel scalar values;
#   list-valued keys get their items joined by a literal ", "), KML_BODY,
#   KML_UNPARSEABLE=1 on structural failure.
_km_lint_parse() {
  local file="$1"
  KML_KEYS=() KML_VALS=() KML_BODY="" KML_UNPARSEABLE=0

  local first_line
  IFS= read -r first_line < "$file" || first_line=""
  if [ "$first_line" != "---" ]; then
    KML_UNPARSEABLE=1
    return 0
  fi

  local lineno=0 closed=0 line body_start=0
  local -a fm=()
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    [ "$lineno" -eq 1 ] && continue
    if [ "$closed" -eq 0 ] && [ "$line" = "---" ]; then
      closed=1
      body_start=$((lineno + 1))
      continue
    fi
    [ "$closed" -eq 0 ] && fm+=("$line")
  done < "$file"

  if [ "$closed" -eq 0 ]; then
    KML_UNPARSEABLE=1
    return 0
  fi
  if [ "$body_start" -gt 0 ]; then
    KML_BODY=$(tail -n "+${body_start}" "$file")
  fi

  local cur_key="" cur_list_items="" cur_is_list=0 cur_parent="" indent rest content
  local raw key val
  _flush() {
    if [ -n "$cur_key" ]; then
      if [ "$cur_is_list" -eq 1 ]; then
        KML_KEYS+=("$cur_key")
        KML_VALS+=("$cur_list_items")
      fi
    fi
    cur_key=""
    cur_list_items=""
    cur_is_list=0
  }

  local fmi
  for ((fmi = 0; fmi < ${#fm[@]}; fmi++)); do
    raw="${fm[fmi]}"
    rest="$raw"
    indent=0
    while [ "${rest:0:1}" = " " ]; do
      indent=$((indent + 1))
      rest="${rest:1}"
    done
    content="$rest"
    [ -z "$content" ] && continue
    case "$content" in
      "- "*)
        if [ "$indent" -ge 2 ] && [ -n "$cur_key" ]; then
          local item="${content#- }"
          item="${item#\"}"
          item="${item%\"}"
          if [ -z "$cur_list_items" ]; then
            cur_list_items="$item"
          else
            cur_list_items="${cur_list_items}, ${item}"
          fi
          cur_is_list=1
        fi
        continue
        ;;
    esac
    case "$content" in
      *:*)
        key="${content%%:*}"
        val="${content#*:}"
        while [ "${val:0:1}" = " " ]; do val="${val:1}"; done
        val="${val%\"}"
        val="${val#\"}"
        ;;
      *)
        continue
        ;;
    esac
    if [ "$indent" -eq 0 ]; then
      _flush
      cur_parent=""
      if [ -n "$val" ]; then
        KML_KEYS+=("$key")
        KML_VALS+=("$val")
      else
        cur_parent="$key"
        cur_key="$key"
        cur_list_items=""
        cur_is_list=0
      fi
    elif [ "$indent" -ge 2 ] && [ -n "$cur_parent" ]; then
      if [ -n "$val" ]; then
        KML_KEYS+=("${cur_parent}.${key}")
        KML_VALS+=("$val")
        cur_is_list=0
      fi
    fi
  done
  _flush
  return 0
}

_km_lint_get() {
  local key="$1" i
  for ((i = 0; i < ${#KML_KEYS[@]}; i++)); do
    [ "${KML_KEYS[i]}" = "$key" ] && { printf '%s\n' "${KML_VALS[i]}"; return 0; }
  done
  return 1
}

_km_lint_has() {
  local key="$1" i
  for ((i = 0; i < ${#KML_KEYS[@]}; i++)); do
    [ "${KML_KEYS[i]}" = "$key" ] && return 0
  done
  return 1
}

_km_lint_count() {
  local key="$1" i n=0
  for ((i = 0; i < ${#KML_KEYS[@]}; i++)); do
    [ "${KML_KEYS[i]}" = "$key" ] && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# --- canonical v1 checks -----------------------------------------------
_km_lint_canonical() {
  local file="$1" v

  for req in name description metadata.type created updated; do
    if ! _km_lint_has "$req"; then
      emit ERROR "$file" "missing required field: $req"
    fi
  done

  if v=$(_km_lint_get metadata.type); then
    _km_lint_in_list "$v" "$KM_LINT_ENUM_TYPE" || emit ERROR "$file" "invalid metadata.type: $v"
  fi

  if v=$(_km_lint_get created); then
    if [ "$v" = "unknown" ]; then
      _km_lint_has migrated || emit ERROR "$file" "created: unknown requires a migrated: date"
    elif ! _km_lint_is_date "$v"; then
      emit ERROR "$file" "created is not an ISO date (YYYY-MM-DD): $v"
    fi
  fi
  if v=$(_km_lint_get updated); then
    _km_lint_is_date "$v" || emit ERROR "$file" "updated is not an ISO date (YYYY-MM-DD): $v"
  fi
  if v=$(_km_lint_get last_verified); then
    _km_lint_is_date "$v" || emit ERROR "$file" "last_verified is not an ISO date (YYYY-MM-DD): $v"
  fi
  if v=$(_km_lint_get review_after); then
    _km_lint_is_date "$v" || emit ERROR "$file" "review_after is not an ISO date (YYYY-MM-DD): $v"
  fi
  if v=$(_km_lint_get migrated); then
    _km_lint_is_date "$v" || emit ERROR "$file" "migrated is not an ISO date (YYYY-MM-DD): $v"
  fi
  if v=$(_km_lint_get status); then
    _km_lint_in_list "$v" "$KM_LINT_ENUM_STATUS" || emit ERROR "$file" "invalid status: $v"
  fi
  if v=$(_km_lint_get confidence); then
    _km_lint_in_list "$v" "$KM_LINT_ENUM_CONFIDENCE" || emit ERROR "$file" "invalid confidence: $v"
  fi
  if v=$(_km_lint_get supersedes); then
    km_is_valid_slug "$v" || emit ERROR "$file" "supersedes is not a canonical slug: $v"
  fi
  if v=$(_km_lint_get tags); then
    local IFS_OLD="$IFS" tag
    IFS=','
    for tag in $v; do
      tag="${tag# }"
      [ -n "$tag" ] || continue
      _km_lint_is_kebab "$tag" || emit ERROR "$file" "tag is not kebab-case: $tag"
    done
    IFS="$IFS_OLD"
  fi

  local stem type
  stem=$(km_stem_of "$file")
  km_is_valid_slug "$stem" || emit ADVISORY "$file" "filename stem does not match the canonical slug regex"

  type=$(_km_lint_get metadata.type 2>/dev/null || true)
  if [ "$type" = "feedback" ] || [ "$type" = "project" ]; then
    case "$KML_BODY" in
      *'**Why:**'*) : ;;
      *) emit ERROR "$file" "missing required body section: **Why:**" ;;
    esac
    case "$KML_BODY" in
      *'**How to apply:**'*) : ;;
      *) emit ERROR "$file" "missing required body section: **How to apply:**" ;;
    esac
  fi
}

# --- legacy checks -------------------------------------------------------
_km_lint_legacy() {
  local file="$1" v stem

  if _km_lint_has type; then
    v=$(_km_lint_get type)
    if _km_lint_in_list "$v" "$KM_LINT_ENUM_TYPE"; then
      emit ADVISORY "$file" "migration: metadata.type: $v (derived from top-level type:)"
    else
      emit ERROR "$file" "ambiguous legacy type value: $v"
    fi
  else
    emit ADVISORY "$file" "migration: metadata.type needs a human value"
  fi

  stem=$(km_stem_of "$file")
  local derived_created=""
  case "$stem" in
    *[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]*)
      derived_created=$(printf '%s\n' "$stem" | grep -Eo '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)
      ;;
    *[0-9][0-9][0-9][0-9]_[0-9][0-9]_[0-9][0-9]*)
      derived_created=$(printf '%s\n' "$stem" | grep -Eo '[0-9]{4}_[0-9]{2}_[0-9]{2}' | head -1 | tr '_' '-')
      ;;
  esac
  if _km_lint_has created; then
    :
  elif [ -n "$derived_created" ]; then
    emit ADVISORY "$file" "migration: created: $derived_created (derived from filename)"
  else
    emit ADVISORY "$file" "migration: created needs a human value (or use created: unknown + migrated:)"
  fi

  if _km_lint_has name; then
    :
  else
    local derived_name
    derived_name=$(printf '%s\n' "$stem" | tr '_-' '  ')
    emit ADVISORY "$file" "migration: name: $derived_name (derived from filename)"
  fi

  for f in description updated; do
    _km_lint_has "$f" || emit ADVISORY "$file" "migration: $f needs a human value"
  done
}

# --- degenerate MEMORY.md index-style advisories -------------------------
_km_lint_index_style() {
  local memory_file="$1" line has_rows=0 prose_lines=0
  while IFS= read -r line; do
    case "$line" in
      "- "*"["*"]("*".md)"*) has_rows=1 ;;
      "#"*) : ;;
      "") : ;;
      *)
        prose_lines=$((prose_lines + 1))
        ;;
    esac
  done < "$memory_file"

  if [ "$has_rows" -eq 0 ] && [ -s "$memory_file" ]; then
    emit ADVISORY "MEMORY.md" "MEMORY.md is free prose with no index rows; propose an index skeleton"
    return 0
  fi
  if [ "$has_rows" -eq 1 ] && [ "$prose_lines" -ge 2 ]; then
    emit ADVISORY "MEMORY.md" "MEMORY.md carries inline knowledge content; propose extraction into memory files"
  fi
}

# --- main -----------------------------------------------------------------
collision_rc=0
collision_count=0
while IFS=$'\t' read -r a b; do
  [ -n "$a" ] || continue
  emit ERROR "$a" "slug collision with $b (after normalization)"
  collision_count=$((collision_count + 1))
done < <(km_slug_collision_pairs "$store" 2>/dev/null)
[ "$collision_count" -eq 0 ] || collision_rc=4

while IFS= read -r symfile; do
  [ -n "$symfile" ] || continue
  emit ERROR "$symfile" "symlinked .md file excluded from the authoritative set"
done < <(km_symlinked_md_files "$store")

if [ "$collision_rc" -eq 0 ]; then
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    file_path="$store/$f"
    _km_lint_parse "$file_path"
    if [ "$KML_UNPARSEABLE" -eq 1 ]; then
      emit ERROR "$f" "unparseable frontmatter"
      continue
    fi
    if _km_lint_has schema_version; then
      _km_lint_canonical "$f"
    else
      _km_lint_legacy "$f"
    fi
  done < <(km_authoritative_files "$store")
fi

_km_lint_index_style "$store/MEMORY.md"

[ "$HAS_ERROR" -eq 0 ] && exit 0
exit 4
