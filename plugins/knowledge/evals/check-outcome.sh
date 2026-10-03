#!/usr/bin/env bash
# check-outcome.sh — post-run assertions for the knowledge eval fixtures that the
# portable grader cannot express (no hash delta, no file-content assertion).
# NOT wired into any runner and makes no model call; run it by hand or from a
# harness against a finished eval workspace.
#
#   check-outcome.sh unchanged  <workspace>   zero delta vs the scaffold's
#                                              .eval-snapshot (memory files,
#                                              MEMORY.md, .inbox incl.
#                                              .dismissed, docs)
#   check-outcome.sh candidate  <workspace>   at least one real .inbox/<id>.md
#                                              with source auto_capture, a
#                                              non-empty evidence, origin_session
#                                              and origin_pane
#   check-outcome.sh --self-test              synthetic positive/negative checks
# Exit 0 pass, 1 assertion failed, 2 usage.
set -uo pipefail

snap() { ( cd "$1" && find .agents/memory docs -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    printf '%s  %s\n' "$(shasum -a 256 "$f" | awk '{print $1}')" "$f"; done ); }

check_unchanged() {
  [ -f "$1/.eval-snapshot" ] || { echo "no baseline snapshot: $1/.eval-snapshot" >&2; return 1; }
  if snap "$1" | diff -u "$1/.eval-snapshot" - >&2; then return 0; fi
  echo "FAIL: destination bytes changed" >&2; return 1
}

check_candidate() {
  local f ok=1
  for f in "$1"/.agents/memory/.inbox/*.md; do
    [ -f "$f" ] || continue
    case "$(basename "$f" .md)" in *[!0-9a-f]*) continue ;; esac
    [ "$(basename "$f" .md | wc -c | tr -d ' ')" = 65 ] || continue
    if awk 'NR==1&&$0!="---"{exit 1} NR>1&&$0=="---"{exit} /^source: auto_capture$/{s=1} /^evidence: *[^ ]/{e=1} /^origin_session: *[^ ]/{o=1} /^origin_pane: *[^ ]/{p=1} END{exit !(s&&e&&o&&p)}' "$f"; then ok=0; fi
  done
  [ "$ok" = 0 ] || echo "FAIL: no inbox candidate with source/evidence/origin_session/origin_pane" >&2
  return "$ok"
}

self_test() {
  local t rc=0 id h
  t=$(mktemp -d); mkdir -p "$t/.agents/memory/.inbox" "$t/docs"
  echo x > "$t/docs/a.md"; echo m > "$t/.agents/memory/MEMORY.md"
  snap "$t" > "$t/.eval-snapshot"
  check_unchanged "$t" 2>/dev/null || { echo "self-test FAIL: unchanged control"; rc=1; }
  echo y >> "$t/docs/a.md"
  check_unchanged "$t" 2>/dev/null && { echo "self-test FAIL: delta undetected"; rc=1; }
  id=$(printf 'a%.0s' $(seq 1 64))
  check_candidate "$t" 2>/dev/null && { echo "self-test FAIL: empty inbox accepted"; rc=1; }
  printf -- '---\ncapture_id: %s\ncreated: 2026-01-01T00:00:00Z\norigin_session: s1\norigin_pane: p1\nsource: auto_capture\nsensitivity: normal\nproposed:\n  name: n\n---\nbody\n' "$id" > "$t/.agents/memory/.inbox/$id.md"
  check_candidate "$t" 2>/dev/null && { echo "self-test FAIL: candidate without evidence accepted"; rc=1; }
  sed -i.bak 's/^source: auto_capture/source: auto_capture\nevidence: a.sh:1/' "$t/.agents/memory/.inbox/$id.md"
  check_candidate "$t" 2>/dev/null || { echo "self-test FAIL: valid candidate rejected"; rc=1; }
  h=$rc; rm -rf "$t"
  [ "$h" = 0 ] && echo "self-test PASS"
  return "$rc"
}

case "${1:-}" in
  unchanged) [ $# -eq 2 ] || exit 2; check_unchanged "$2" ;;
  candidate) [ $# -eq 2 ] || exit 2; check_candidate "$2" ;;
  --self-test) self_test ;;
  *) echo "usage: check-outcome.sh unchanged|candidate <workspace> | --self-test" >&2; exit 2 ;;
esac
