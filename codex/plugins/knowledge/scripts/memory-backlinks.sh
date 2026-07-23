#!/usr/bin/env bash
# memory-backlinks.sh — [[slug]] link graph: resolution report, neighbors,
# reverse links, orphans, weakly-connected components, and whole-graph
# JSON/DOT/Mermaid output (read-only). ONE authority for link parsing,
# slug normalization, and graph output schemas. Implements the `graph`
# command surface (commands/graph.md); also exposes a "report" mode (the
# per-link convention-drift/dangling warning lines) for future callers
# (e.g. a Phase C doctor) — this mode is this script's own extension of the
# spec's shared-resolver emission contract, not itself bound to a v1
# command surface.
#
# Usage:
#   memory-backlinks.sh [--store <path>] report
#   memory-backlinks.sh [--store <path>] neighbors <slug>
#   memory-backlinks.sh [--store <path>] reverse <slug>
#   memory-backlinks.sh [--store <path>] orphans
#   memory-backlinks.sh [--store <path>] components
#   memory-backlinks.sh [--store <path>] graph [--format json|dot|mermaid]
#
# Exit codes: 0 ok (including empty results); 2 usage/bad argv/unresolved
#   slug; 3 store resolution failure; 4 store-integrity error (collision,
#   unsafe stem).
# Supported platforms: macOS, Linux
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"

USAGE="usage: memory-backlinks.sh [--store <path>] {report|neighbors <slug>|reverse <slug>|orphans|components|graph [--format json|dot|mermaid]}"

store_arg=""
declare -a args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --store)
      [ $# -ge 2 ] || { echo "$USAGE" >&2; exit 2; }
      store_arg="$2"
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

mode="${args[0]:-}"
slug_arg=""
format="json"
case "$mode" in
  report|orphans|components)
    [ "${#args[@]}" -eq 1 ] || { echo "$USAGE" >&2; exit 2; }
    ;;
  neighbors|reverse)
    [ "${#args[@]}" -eq 2 ] || { echo "$USAGE" >&2; exit 2; }
    slug_arg="${args[1]}"
    ;;
  graph)
    if [ "${#args[@]}" -eq 1 ]; then
      :
    elif [ "${#args[@]}" -eq 3 ] && [ "${args[1]}" = "--format" ]; then
      format="${args[2]}"
      case "$format" in
        json|dot|mermaid) ;;
        *) echo "$USAGE" >&2; exit 2 ;;
      esac
    else
      echo "$USAGE" >&2
      exit 2
    fi
    ;;
  *)
    echo "$USAGE" >&2
    exit 2
    ;;
esac

store=$(km_resolve_store "$store_arg") || exit $?
km_slug_collision_check "$store" || exit 4

declare -a auth_files=()
while IFS= read -r f; do
  [ -n "$f" ] && auth_files+=("$f")
done < <(km_authoritative_files "$store")

unsafe=""
if [ "${#auth_files[@]}" -gt 0 ]; then
  for f in "${auth_files[@]}"; do
    stem="${f%.md}"
    case "$stem" in
      *[!A-Za-z0-9._-]*) unsafe="$unsafe $f" ;;
    esac
  done
fi
if [ -n "$unsafe" ]; then
  echo "ERROR: unsafe stem(s) outside the safe stem grammar [A-Za-z0-9._-]:$unsafe" >&2
  exit 4
fi

declare -a all_stems=()
if [ "${#auth_files[@]}" -gt 0 ]; then
  for f in "${auth_files[@]}"; do
    all_stems+=("${f%.md}")
  done
fi
n=${#all_stems[@]}

WORKDIR="$(mktemp -d)"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT

# --- extract body text (everything after the closing frontmatter fence, or
# the whole file when it doesn't open with one) ---
_km_bl_body_of() {
  awk '
    NR==1 { if ($0=="---") { infm=1; next } else { print; next } }
    infm==1 && $0=="---" { infm=0; next }
    infm==1 { next }
    { print }
  ' "$1"
}

# --- one raw [[link]] target per line (may repeat) ---
_km_bl_extract_links() {
  _km_bl_body_of "$1" | grep -oE '\[\[[^]]+\]\]' | sed -E 's/^\[\[//; s/\]\]$//'
}

links_raw="$WORKDIR/links_raw.tsv"
: > "$links_raw"
if [ "${#auth_files[@]}" -gt 0 ]; then
  for f in "${auth_files[@]}"; do
    from_stem="${f%.md}"
    while IFS= read -r link; do
      [ -n "$link" ] || continue
      printf '%s\t%s\n' "$from_stem" "$link" >> "$links_raw"
    done < <(_km_bl_extract_links "$store/$f")
  done
fi

# --- link resolution (uses lib.sh's shared km_resolve_slug directly; a
# helper is needed only to smuggle its KM_RESOLVE_KIND side-effect out of a
# stdout capture without losing it to a command-substitution subshell) ---
_KM_BL_RESOLVE_TMP="$WORKDIR/resolve.out"
_km_bl_resolve() {
  local store="$1" link="$2"
  if km_resolve_slug "$store" "$link" > "$_KM_BL_RESOLVE_TMP" 2>/dev/null; then
    _KM_BL_LAST_KIND="$KM_RESOLVE_KIND"
    _KM_BL_LAST_RESOLVED=$(cat "$_KM_BL_RESOLVE_TMP")
    return 0
  fi
  _KM_BL_LAST_KIND="$KM_RESOLVE_KIND"
  _KM_BL_LAST_RESOLVED=""
  return 1
}

edges_resolved="$WORKDIR/edges_resolved.tsv"   # from<TAB>to (resolved; may repeat)
drift_pairs="$WORKDIR/drift_pairs.tsv"         # raw-link<TAB>resolved (may repeat)
dangling_links="$WORKDIR/dangling_links.txt"   # raw-link (may repeat)
dangling_pairs="$WORKDIR/dangling_pairs.tsv"   # from<TAB>raw-link (may repeat)
: > "$edges_resolved"; : > "$drift_pairs"; : > "$dangling_links"; : > "$dangling_pairs"

while IFS=$'\t' read -r from link; do
  [ -n "$from" ] || continue
  if _km_bl_resolve "$store" "$link"; then
    printf '%s\t%s\n' "$from" "$_KM_BL_LAST_RESOLVED" >> "$edges_resolved"
    if [ "$_KM_BL_LAST_KIND" = "drift" ]; then
      printf '%s\t%s\n' "$link" "$_KM_BL_LAST_RESOLVED" >> "$drift_pairs"
    fi
  else
    printf '%s\n' "$link" >> "$dangling_links"
    printf '%s\t%s\n' "$from" "$link" >> "$dangling_pairs"
  fi
done < "$links_raw"

edges_dedup="$WORKDIR/edges_dedup.tsv"
LC_ALL=C sort -u "$edges_resolved" > "$edges_dedup"

dangling_count=$(LC_ALL=C sort -u "$dangling_pairs" | grep -c . || true)

# --- report mode: per-distinct-link literal WARN lines, sorted asc (C
# locale) by link text, to stderr. Convention drift and dangling findings
# are merged into one link-ordered stream (each link is exactly one kind). ---
if [ "$mode" = "report" ]; then
  report_lines="$WORKDIR/report_lines.tsv"
  : > "$report_lines"
  LC_ALL=C sort -u -t "$(printf '\t')" -k1,1 "$drift_pairs" | while IFS=$'\t' read -r link resolved; do
    [ -n "$link" ] || continue
    printf '%s\tconvention drift: [[%s]] -> %s\n' "$link" "$link" "$resolved" >> "$report_lines"
  done
  LC_ALL=C sort -u "$dangling_links" | while IFS= read -r link; do
    [ -n "$link" ] || continue
    printf '%s\tdangling: [[%s]]\n' "$link" "$link" >> "$report_lines"
  done
  if [ -s "$report_lines" ]; then
    LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$report_lines" | while IFS=$'\t' read -r _ msg; do
      echo "$msg" >&2
    done
  fi
  exit 0
fi

# --- neighbors / reverse: resolve the given slug first (exact-stem then
# unique-normalized, like any read-path lookup); unresolved is exit 2. ---
if [ "$mode" = "neighbors" ] || [ "$mode" = "reverse" ]; then
  if _km_bl_resolve "$store" "$slug_arg"; then
    resolved_slug="$_KM_BL_LAST_RESOLVED"
  else
    echo "unknown slug: $slug_arg" >&2
    exit 2
  fi
fi

case "$mode" in
  neighbors)
    {
      awk -F'\t' -v s="$resolved_slug" '$2==s {print "in\t" $1}' "$edges_dedup"
      awk -F'\t' -v s="$resolved_slug" '$1==s {print "out\t" $2}' "$edges_dedup"
    } | LC_ALL=C sort -t "$(printf '\t')" -k1,1 -k2,2
    ;;
  reverse)
    awk -F'\t' -v s="$resolved_slug" '$2==s {print $1}' "$edges_dedup" | LC_ALL=C sort -u
    ;;
  orphans)
    touched="$WORKDIR/touched.txt"
    { cut -f1 "$edges_dedup"; cut -f2 "$edges_dedup"; } | LC_ALL=C sort -u > "$touched"
    all_stems_file="$WORKDIR/all_stems.txt"
    : > "$all_stems_file"
    if [ "$n" -gt 0 ]; then
      for s in "${all_stems[@]}"; do printf '%s\n' "$s"; done | LC_ALL=C sort -u > "$all_stems_file"
    fi
    LC_ALL=C comm -23 "$all_stems_file" "$touched"
    ;;
  components)
    declare -a parent=()
    for ((i = 0; i < n; i++)); do parent[i]=$i; done

    _km_bl_find_index() {
      local target="$1" i
      for ((i = 0; i < n; i++)); do
        if [ "${all_stems[i]}" = "$target" ]; then
          REPLY=$i
          return 0
        fi
      done
      REPLY=-1
      return 1
    }
    _km_bl_uf_find() {
      local x="$1"
      while [ "${parent[x]}" != "$x" ]; do
        x=${parent[x]}
      done
      REPLY=$x
    }
    _km_bl_uf_union() {
      local a="$1" b="$2" ra rb
      _km_bl_uf_find "$a"; ra=$REPLY
      _km_bl_uf_find "$b"; rb=$REPLY
      if [ "$ra" != "$rb" ]; then
        if [ "$ra" -lt "$rb" ]; then parent[rb]=$ra; else parent[ra]=$rb; fi
      fi
    }

    if [ "$n" -gt 0 ]; then
      while IFS=$'\t' read -r from to; do
        [ -n "$from" ] || continue
        _km_bl_find_index "$from"; fi_=$REPLY
        _km_bl_find_index "$to"; ti_=$REPLY
        [ "$fi_" -ge 0 ] && [ "$ti_" -ge 0 ] || continue
        _km_bl_uf_union "$fi_" "$ti_"
      done < "$edges_dedup"

      comp_file="$WORKDIR/comp.tsv"
      : > "$comp_file"
      for ((i = 0; i < n; i++)); do
        _km_bl_uf_find "$i"
        printf '%s\t%s\n' "$REPLY" "${all_stems[i]}" >> "$comp_file"
      done
      awk -F'\t' '
        { if (!($1 in first)) { first[$1] = $2 }
          members[$1] = (members[$1] == "" ? $2 : members[$1] " " $2) }
        END { for (r in first) print first[r] "\t" members[r] }
      ' "$comp_file" | LC_ALL=C sort -t "$(printf '\t')" -k1,1 | cut -f2-
    fi
    ;;
  graph)
    # --- node metadata (type/status/tags), needed only for --format json ---
    _km_bl_node_meta() {
      awk '
        BEGIN { meta_type=""; legacy_type=""; status_val=""; tags="" }
        NR==1 { if ($0=="---") { infm=1; next } else { exit } }
        infm==1 && $0=="---" { infm=0; exit }
        infm==1 {
          line=$0
          indent=0
          tmp=line
          while (substr(tmp,1,1)==" ") { indent++; tmp=substr(tmp,2) }
          if (tmp=="") next
          if (substr(tmp,1,2)=="- ") {
            if (indent>=2 && cur=="tags") {
              item=substr(tmp,3)
              gsub(/^"/,"",item); gsub(/"$/,"",item)
              tags = (tags=="") ? item : tags "," item
            }
            next
          }
          colon = index(tmp, ":")
          if (colon==0) next
          key = substr(tmp,1,colon-1)
          val = substr(tmp,colon+1)
          sub(/^ +/, "", val)
          gsub(/^"/,"",val); gsub(/"$/,"",val)
          if (indent==0) {
            cur = key
            if (val != "") {
              if (key=="type") legacy_type=val
              else if (key=="status") status_val=val
              cur=""
            }
          } else if (indent>=2) {
            if (key=="type" && cur=="metadata") meta_type=val
          }
        }
        END {
          t = (meta_type!="") ? meta_type : legacy_type
          if (t=="") t="unknown"
          s = (status_val!="") ? status_val : "active"
          printf "%s\t%s\t%s\n", t, s, tags
        }
      ' "$1"
    }
    _km_bl_json_escape() {
      local s
      s=$(printf '%s' "$1" | tr '\t\r\n' '   ')
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      printf '%s' "$s"
    }
    _km_bl_dot_escape() {
      local s="$1"
      s="${s//\\/\\\\}"
      s="${s//\"/\\\"}"
      printf '%s' "$s"
    }
    _km_bl_mermaid_label() {
      printf '%s' "${1//\"/#quot;}"
    }
    _km_bl_tags_json() {
      local csv="$1" tag out="" is_first=1
      local IFS=','
      for tag in $csv; do
        [ -n "$tag" ] || continue
        if [ "$is_first" -eq 1 ]; then is_first=0; else out="$out,"; fi
        out="$out\"$(_km_bl_json_escape "$tag")\""
      done
      printf '%s' "$out"
    }
    _km_bl_find_index() {
      local target="$1" i
      for ((i = 0; i < n; i++)); do
        if [ "${all_stems[i]}" = "$target" ]; then
          REPLY=$i
          return 0
        fi
      done
      REPLY=-1
      return 1
    }

    case "$format" in
      json)
        out='{"nodes":['
        first=1
        if [ "$n" -gt 0 ]; then
          for ((i = 0; i < n; i++)); do
            stem="${all_stems[i]}"
            meta=$(_km_bl_node_meta "$store/$stem.md")
            IFS=$'\t' read -r type status tags <<< "$meta"
            [ -n "$type" ] || type="unknown"
            [ -n "$status" ] || status="active"
            if [ "$first" -eq 1 ]; then first=0; else out="$out,"; fi
            out="$out{\"slug\":\"$(_km_bl_json_escape "$stem")\",\"type\":\"$(_km_bl_json_escape "$type")\",\"status\":\"$(_km_bl_json_escape "$status")\",\"tags\":[$(_km_bl_tags_json "$tags")]}"
          done
        fi
        out="$out],\"edges\":["
        first=1
        while IFS=$'\t' read -r from to; do
          [ -n "$from" ] || continue
          if [ "$first" -eq 1 ]; then first=0; else out="$out,"; fi
          out="$out{\"from\":\"$(_km_bl_json_escape "$from")\",\"to\":\"$(_km_bl_json_escape "$to")\"}"
        done < "$edges_dedup"
        out="$out]}"
        printf '%s\n' "$out"
        ;;
      dot)
        {
          echo 'digraph knowledge {'
          if [ "$n" -gt 0 ]; then
            for stem in "${all_stems[@]}"; do
              printf '"%s";\n' "$(_km_bl_dot_escape "$stem")"
            done
          fi
          while IFS=$'\t' read -r from to; do
            [ -n "$from" ] || continue
            printf '"%s" -> "%s";\n' "$(_km_bl_dot_escape "$from")" "$(_km_bl_dot_escape "$to")"
          done < "$edges_dedup"
          echo '}'
        }
        ;;
      mermaid)
        {
          echo 'flowchart LR'
          if [ "$n" -gt 0 ]; then
            for ((i = 0; i < n; i++)); do
              printf 'n%d["%s"]\n' "$i" "$(_km_bl_mermaid_label "${all_stems[i]}")"
            done
          fi
          while IFS=$'\t' read -r from to; do
            [ -n "$from" ] || continue
            _km_bl_find_index "$from"; fi_=$REPLY
            _km_bl_find_index "$to"; ti_=$REPLY
            [ "$fi_" -ge 0 ] && [ "$ti_" -ge 0 ] || continue
            printf 'n%d --> n%d\n' "$fi_" "$ti_"
          done < "$edges_dedup"
        }
        ;;
    esac
    ;;
esac

if [ "$mode" != "report" ] && [ "$dangling_count" -gt 0 ]; then
  echo "dangling: $dangling_count" >&2
fi

exit 0
