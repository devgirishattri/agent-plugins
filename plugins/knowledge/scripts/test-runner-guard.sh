#!/usr/bin/env bash
# test-runner-guard.sh — regression for test-knowledge.sh's false-green guard.
# A module suite that calls an undefined helper prints "command not found" and
# can still print "N passed, 0 failed" with exit 0. The runner must fail it.
# Runs a COPY of test-knowledge.sh against fake module suites in a temp dir.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0 FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL  $1 -- $2"; }
TMP="$(mktemp -d "${TMPDIR:-/tmp}/knowledge-runner-guard.XXXXXX")" || { echo "ERROR: cannot allocate temp dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT
cp "$HERE/test-knowledge.sh" "$TMP/test-knowledge.sh"

run_case() { # $1 label, $2 expected rc class (zero|nonzero), $3 fake suite body
  printf '%s\n' "$3" > "$TMP/test-context.sh"
  local out rc
  out="$(cd "$TMP" && /bin/bash "$TMP/test-knowledge.sh" --suite context 2>&1)"; rc=$?
  if [ "$2" = zero ] && [ "$rc" -eq 0 ]; then pass "$1"
  elif [ "$2" = nonzero ] && [ "$rc" -ne 0 ]; then pass "$1"
  else fail "$1" "rc=$rc out=$(printf '%s' "$out" | tail -n 3 | tr '\n' '|')"; fi
  LAST_OUT="$out"
}

# Control: a clean suite with a normal summary passes.
run_case guard_control_clean_suite_passes zero '#!/usr/bin/env bash
echo "  PASS  something"
echo "=== 1 passed, 0 failed ==="
exit 0'
# Negative: an undefined helper (command not found in the suite file) with a
# fake green summary and exit 0 must fail.
run_case guard_missing_helper_fake_green_fails nonzero '#!/usr/bin/env bash
assert_missing_helper some_label "" ""
echo "=== 1 passed, 0 failed ==="
exit 0'
case "$LAST_OUT" in *"command not found"*) pass guard_reports_reason ;; *) fail guard_reports_reason "no reason line" ;; esac
# Control: "command not found" text from a child process (not the suite file
# itself) does not trip the guard.
run_case guard_child_not_found_text_ignored zero '#!/usr/bin/env bash
echo "/some/other/helper.sh: line 3: foo: command not found"
echo "=== 1 passed, 0 failed ==="
exit 0'
# Negative with large output: the missing helper comes first, then >200KB of
# trailing output and a fake green summary. Guards against SIGPIPE false
# negatives in the runner's detection pipeline.
run_case guard_missing_helper_large_output_fails nonzero '#!/usr/bin/env bash
assert_missing_helper some_label "" ""
i=0; while [ "$i" -lt 4000 ]; do echo "  PASS  filler_line_$i padding padding padding padding padding"; i=$((i + 1)); done
echo "=== 4000 passed, 0 failed ==="
exit 0'
# Control: the same large output without the missing helper passes.
run_case guard_large_output_control_passes zero '#!/usr/bin/env bash
i=0; while [ "$i" -lt 4000 ]; do echo "  PASS  filler_line_$i padding padding padding padding padding"; i=$((i + 1)); done
echo "=== 4000 passed, 0 failed ==="
exit 0'
echo "=== runner-guard tests: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
