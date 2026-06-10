#!/usr/bin/env bash
# task-board.sh — At-a-glance dashboard of active (non-done) scheduler tasks
# Groups tasks by stage (or "(none)"), one aligned row per task:
#   id, name, status, assignee, age (since created_at), flags, unmet deps.
# Ends with a one-line totals summary. Plain text, no color codes.
# Usage: task-board.sh
# Supported platforms: macOS, Linux
set -uo pipefail

source "$(dirname "$0")/lib.sh"

require_jq || exit 1
ensure_dirs

NOW=$(now_epoch)
rows=""
total=0
n_created=0; n_assigned=0; n_review=0; n_blocked=0; n_overdue=0; n_stale=0

for file in "$TASKS_DIR"/*.json; do
  [ -f "$file" ] || continue
  status=$(jq -r '.status // ""' "$file" 2>/dev/null) || continue
  case "$status" in
    created)  n_created=$((n_created + 1)) ;;
    assigned) n_assigned=$((n_assigned + 1)) ;;
    review)   n_review=$((n_review + 1)) ;;
    blocked)  n_blocked=$((n_blocked + 1)) ;;
    *) continue ;;  # done (or unknown) tasks are not shown on the board
  esac
  total=$((total + 1))

  base=$(jq -r '[(.stage // "(none)"), .id, .name, .status, (if (.assignee // "") == "" then "-" else .assignee end), .created_at] | @tsv' "$file" 2>/dev/null) || continue
  stage=$(printf '%s' "$base" | cut -f1)
  id=$(printf '%s' "$base" | cut -f2)
  name=$(printf '%s' "$base" | cut -f3)
  assignee=$(printf '%s' "$base" | cut -f5)
  created_at=$(printf '%s' "$base" | cut -f6)

  age="-"
  created_epoch=$(iso_to_epoch "$created_at")
  [ "$created_epoch" -gt 0 ] && age=$(humanize_age $((NOW - created_epoch)))

  flags=$(task_flags "$file")
  case "$flags" in *OVERDUE*) n_overdue=$((n_overdue + 1)) ;; esac
  case "$flags" in *STALE*) n_stale=$((n_stale + 1)) ;; esac

  unmet_count=0
  unmet=$(unmet_deps "$id")
  [ -n "$unmet" ] && unmet_count=$(printf '%s\n' "$unmet" | grep -c .)
  deps_col="-"
  [ "$unmet_count" -gt 0 ] && deps_col="${unmet_count} unmet"

  rows="${rows}${stage}	${id}	${name}	${status}	${assignee}	${age}	${flags}	${deps_col}
"
done

echo "=== Task Board ==="
if [ "$total" -eq 0 ]; then
  echo "No active tasks. Create one with \$session-scheduler:task-new <name>."
  exit 0
fi
echo

# Sort by stage, then align columns and print one group per stage via awk.
printf '%s' "$rows" | sort -t '	' -k1,1 -k2,2 | awk -F'\t' '
  BEGIN {
    h[2] = "ID"; h[3] = "NAME"; h[4] = "STATUS"; h[5] = "ASSIGNEE"
    h[6] = "AGE"; h[7] = "FLAGS"; h[8] = "DEPS"
    for (i = 2; i <= 8; i++) w[i] = length(h[i])
  }
  {
    nrows++
    row[nrows] = $0
    for (i = 2; i <= NF; i++) if (length($i) > w[i]) w[i] = length($i)
  }
  END {
    prev = ""
    for (r = 1; r <= nrows; r++) {
      n = split(row[r], f, "\t")
      if (f[1] != prev) {
        if (prev != "") print ""
        print "Stage: " f[1]
        line = "  "
        for (i = 2; i <= 8; i++) line = line sprintf("%-" w[i] "s  ", h[i])
        sub(/ +$/, "", line); print line
        prev = f[1]
      }
      line = "  "
      for (i = 2; i <= n; i++) line = line sprintf("%-" w[i] "s  ", f[i])
      sub(/ +$/, "", line); print line
    }
  }'

summary="${total} active:"
sep=" "
[ "$n_created"  -gt 0 ] && { summary="${summary}${sep}${n_created} created"; sep=", "; }
[ "$n_assigned" -gt 0 ] && { summary="${summary}${sep}${n_assigned} assigned"; sep=", "; }
[ "$n_review"   -gt 0 ] && { summary="${summary}${sep}${n_review} review"; sep=", "; }
[ "$n_blocked"  -gt 0 ] && { summary="${summary}${sep}${n_blocked} blocked"; sep=", "; }
[ "$n_overdue"  -gt 0 ] && summary="${summary}; ${n_overdue} overdue"
[ "$n_stale"    -gt 0 ] && summary="${summary}; ${n_stale} stale"

echo
echo "$summary"
