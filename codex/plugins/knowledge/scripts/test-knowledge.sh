#!/usr/bin/env bash
# test-knowledge.sh — Phase F consolidated test runner for the knowledge
# plugin (provider-neutral; ships in both trees). Runs every module test
# suite (A through E) plus two
# Phase-F-owned release-hardening checks that no single module suite owns:
#
#   (a) network-egress — ONE authoritative zero-network-egress static sweep
#       across every shipped helper script in this directory. Each phase's
#       own suite already carries a PARTIAL sweep scoped to that phase's
#       scripts (test-memory-kernel.sh, test-retrieval.sh,
#       test-consolidate.sh, test-promotion.sh); this check is the single
#       sweep that covers every helper, including ones no phase-specific
#       suite happened to list (check-freshness.sh, check-todos.sh,
#       detect-snapshots.sh, diff-context.sh, docs-write.sh, list-contexts.sh,
#       load-context.sh, remove-context.sh, search-contexts.sh,
#       share-context.sh, validate-links.sh). Per the security and constraint
#       contract:
#       "helper scripts contain no network client invocation ... asserted by
#       static grep in the test suite, and the suite passes with network
#       access denied."
#   (b) privacy — fails if any real (non-synthetic) project identifier
#       leaks into this plugin's own tree (fixtures, skills, commands,
#       assets must be fully synthetic — ProjectA/ProjectB style — per the
#       spec's Privacy note at the top of the file).
#
# Usage:
#   bash test-knowledge.sh                 # run every suite + both F checks
#   bash test-knowledge.sh --suite <name>  # run exactly one, see NAMES below
#   bash test-knowledge.sh -v              # verbose; forwarded to module suites
#   bash test-knowledge.sh --suite <name> -v
#
# NAMES (module suites, in component-inventory order):
#   context docs-create memory-kernel retrieval capture
#   consolidate doctor promotion
# NAMES (Phase-F-owned checks, run inline by this script):
#   network-egress privacy
#
# Exit: 0 iff every requested suite/check is green (aggregate, when no
# --suite is given: 0 iff ALL TEN are green); 1 if any is red; 2 usage error.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KNOWLEDGE_DIR="$(cd "$HERE/.." && pwd)"

# ---------------------------------------------------------------------------
# argv — exhaustive: [--suite NAME] [-v] [-h|--help]
# ---------------------------------------------------------------------------
VERBOSE=""
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --suite)
      if [ $# -lt 2 ]; then
        echo "ERROR: --suite requires a NAME argument" >&2
        exit 2
      fi
      ONLY="$2"
      shift 2
      ;;
    -v)
      VERBOSE="1"
      shift
      ;;
    -h|--help)
      sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unrecognized argument: $1" >&2
      echo "Usage: bash test-knowledge.sh [--suite NAME] [-v]" >&2
      exit 2
      ;;
  esac
done

MODULE_NAMES="context docs-create memory-kernel retrieval capture consolidate doctor promotion"
CHECK_NAMES="network-egress privacy"
ALL_NAMES="$MODULE_NAMES $CHECK_NAMES"

is_known_name() {
  local n="$1" candidate
  for candidate in $ALL_NAMES; do
    if [ "$candidate" = "$n" ]; then
      return 0
    fi
  done
  return 1
}

if [ -n "$ONLY" ] && ! is_known_name "$ONLY"; then
  echo "ERROR: unknown --suite '$ONLY' (valid: $ALL_NAMES)" >&2
  exit 2
fi

# ---------------------------------------------------------------------------
# module-suite dispatch
# ---------------------------------------------------------------------------
module_script_for() {
  case "$1" in
    context)         echo "test-context.sh" ;;
    docs-create)     echo "test-docs-create.sh" ;;
    memory-kernel)   echo "test-memory-kernel.sh" ;;
    retrieval)       echo "test-retrieval.sh" ;;
    capture)         echo "test-capture.sh" ;;
    consolidate)     echo "test-consolidate.sh" ;;
    doctor)          echo "test-doctor.sh" ;;
    promotion)       echo "test-promotion.sh" ;;
    *) return 1 ;;
  esac
}

# Runs one module suite under the system bash, prints one summary row, and
# on failure prints the suite's full captured output indented for triage.
# Returns the suite's own exit code (0 pass, non-zero fail).
run_module() {
  local name="$1" script path out rc t0 t1 dur summary sp sf extra_args
  script="$(module_script_for "$name")"
  path="$HERE/$script"
  if [ ! -f "$path" ]; then
    printf '  FAIL  %-16s missing script: %s\n' "$name" "$script"
    return 1
  fi
  extra_args=()
  if [ -n "$VERBOSE" ]; then
    extra_args=("-v")
  fi
  t0="$(date +%s)"
  if [ "${#extra_args[@]}" -gt 0 ]; then
    out="$(/bin/bash "$path" "${extra_args[@]}" 2>&1)"
  else
    out="$(/bin/bash "$path" 2>&1)"
  fi
  rc=$?
  t1="$(date +%s)"
  dur=$((t1 - t0))
  summary="$(printf '%s\n' "$out" | grep -oE '[0-9]+ passed, [0-9]+ failed' | tail -n 1)"
  if [ -z "$summary" ]; then
    summary="(no pass/fail summary line found)"
  fi
  sp="$(printf '%s\n' "$summary" | grep -oE '^[0-9]+' || true)"
  sf="$(printf '%s\n' "$summary" | grep -oE '[0-9]+ failed' | grep -oE '^[0-9]+' || true)"
  if [ -n "$sp" ]; then SUM_ASSERT_PASS=$((SUM_ASSERT_PASS + sp)); fi
  if [ -n "$sf" ]; then SUM_ASSERT_FAIL=$((SUM_ASSERT_FAIL + sf)); fi
  if [ "$rc" -eq 0 ]; then
    printf '  PASS  %-16s %-24s (%ss)\n' "$name" "$summary" "$dur"
  else
    printf '  FAIL  %-16s %-24s (%ss)\n' "$name" "$summary" "$dur"
    echo "        ---- $name: full output (exit $rc) ----"
    printf '%s\n' "$out" | sed 's/^/        /'
    echo "        ---- end $name ----"
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# (a) network-egress — authoritative zero-network-egress static sweep
# ---------------------------------------------------------------------------
check_network_egress() {
  local pattern='curl|wget|[^a-zA-Z]nc[[:space:]]|http\.client|urllib|requests\.|socket\.connect'
  local hits="" f base n=0
  # Sweep EVERY shipped helper script directly in this directory. test-*.sh
  # harnesses are excluded: each one embeds this exact grep pattern as
  # literal source text for its own (now-superseded by this authoritative
  # check) per-phase egress assertion, which would always self-match this
  # sweep's own pattern -- the same convention already established and
  # reviewed in test-memory-kernel.sh / test-retrieval.sh /
  # test-consolidate.sh / test-promotion.sh ("this test script itself is
  # deliberately excluded ... only scanning the scripts under test"). Test
  # harnesses are never invoked by any command/skill at runtime, so they are
  # not "helper scripts" in the spec's zero-egress sense; this script itself
  # (test-knowledge.sh) is excluded for the identical self-match reason.
  for f in "$HERE"/*.sh; do
    base="$(basename "$f")"
    case "$base" in
      test-*.sh) continue ;;
    esac
    n=$((n + 1))
    if grep -Eniq "$pattern" "$f" 2>/dev/null; then
      hits="$hits $base"
    fi
  done
  if [ -z "$hits" ]; then
    printf '  PASS  %-16s zero network-client invocations across %d helper scripts\n' "network-egress" "$n"
    return 0
  fi
  printf '  FAIL  %-16s matches in:%s\n' "network-egress" "$hits"
  return 1
}

# ---------------------------------------------------------------------------
# (b) privacy — real-project-identifier sweep (synthetic content only)
# ---------------------------------------------------------------------------
check_privacy() {
  # The real-project-identifier denylist is intentionally kept OUT of this
  # public repository. Configure it out-of-band to run the sweep:
  #   - env KNOWLEDGE_PRIVACY_DENYLIST=/abs/path (one identifier per line;
  #     blank lines and '#' comments are ignored), or
  #   - a gitignored '.privacy-denylist' at the repository root.
  # With no denylist configured (a clean public checkout, or CI without the
  # secret) the sweep is a no-op PASS -- there is nothing to match against.
  local repo_root denylist_file pattern
  repo_root="$(git -C "$KNOWLEDGE_DIR" rev-parse --show-toplevel 2>/dev/null || echo "$KNOWLEDGE_DIR")"
  denylist_file="${KNOWLEDGE_PRIVACY_DENYLIST:-$repo_root/.privacy-denylist}"
  if [ ! -f "$denylist_file" ]; then
    printf '  PASS  %-16s skipped (no denylist configured; set KNOWLEDGE_PRIVACY_DENYLIST or add .privacy-denylist)\n' "privacy"
    return 0
  fi
  pattern="$(grep -vE '^[[:space:]]*(#|$)' "$denylist_file" 2>/dev/null | paste -sd'|' -)"
  if [ -z "$pattern" ]; then
    printf '  PASS  %-16s skipped (denylist empty)\n' "privacy"
    return 0
  fi

  local hits="" f rel n=0 match_out
  while IFS= read -r f; do
    rel="${f#"$KNOWLEDGE_DIR"/}"
    n=$((n + 1))
    # -I skips files grep detects as binary (none expected here, but this
    # keeps the sweep from erroring on one); -i for case variants (the
    # identifiers must never appear regardless of capitalization).
    match_out="$(grep -IinE "$pattern" "$f" 2>/dev/null || true)"
    if [ -n "$match_out" ]; then
      hits="$hits
    $rel:
$(printf '%s\n' "$match_out" | sed 's/^/      /')"
    fi
  done < <(find "$KNOWLEDGE_DIR" -type f)

  if [ -z "$hits" ]; then
    printf '  PASS  %-16s no real-project identifiers found across %d files\n' "privacy" "$n"
    return 0
  fi
  printf '  FAIL  %-16s real-project identifier(s) found (investigate -- fixtures must be synthetic, ProjectA/ProjectB style):%s\n' "privacy" "$hits"
  return 1
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
SUM_ASSERT_PASS=0
SUM_ASSERT_FAIL=0
OVERALL_RC=0
FAILED_NAMES=""
RUN_COUNT=0
PASS_COUNT=0

names_to_run="$ALL_NAMES"
if [ -n "$ONLY" ]; then
  names_to_run="$ONLY"
fi

echo "=== knowledge plugin test suite ==="
echo

for name in $names_to_run; do
  RUN_COUNT=$((RUN_COUNT + 1))
  case "$name" in
    context|docs-create|memory-kernel|retrieval|capture|consolidate|doctor|promotion)
      run_module "$name"
      rc=$?
      ;;
    network-egress)
      check_network_egress
      rc=$?
      ;;
    privacy)
      check_privacy
      rc=$?
      ;;
    *)
      echo "ERROR: internal: unknown name $name" >&2
      rc=2
      ;;
  esac
  if [ "$rc" -eq 0 ]; then
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    OVERALL_RC=1
    FAILED_NAMES="$FAILED_NAMES $name"
  fi
done

echo
echo "=== knowledge: $PASS_COUNT/$RUN_COUNT suites+checks green (module-suite assertions: $SUM_ASSERT_PASS passed, $SUM_ASSERT_FAIL failed) ==="
if [ "$OVERALL_RC" -ne 0 ]; then
  echo "Failed:$FAILED_NAMES"
fi

exit $OVERALL_RC
