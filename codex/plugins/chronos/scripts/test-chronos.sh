#!/usr/bin/env bash
# Functional gate for chronos (Codex tree).
#
# chronos is hook-only — no commands, no skills — so it was invisible to every
# per-plugin test gate until this suite existed: a `test-*.sh` glob found nothing
# to run and reported success. What it emits is injected into every turn, and a
# silent failure (bad JSON, a wrong timezone, a hook that exits non-zero) either
# corrupts context or breaks the turn.
#
# This is NOT a mirror of the Claude-tree suite. The Codex script is deliberately
# narrower: UserPromptSubmit only, no session state, no PreToolUse throttling, no
# CHRONOS_INTERVAL_MIN, and it builds its JSON with a hand-rolled escaper instead
# of depending on jq. Those differences are what this file tests.
#
# Accumulating, not fail-fast: every check runs and the suite reports
# "<passed> passed, <failed> failed".
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT="$HERE/inject-current-time.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); }
fail() {
	FAIL=$((FAIL + 1))
	printf 'FAIL: %s\n' "$1" >&2
	[ $# -gt 1 ] && printf '      %s\n' "$2" >&2
	return 0
}
check() {
	# check DESCRIPTION EXPECTED ACTUAL
	if [ "$2" = "$3" ]; then pass; else fail "$1" "expected [$2] got [$3]"; fi
}

[ -f "$SCRIPT" ] || {
	printf 'chronos: missing %s\n' "$SCRIPT" >&2
	exit 1
}
command -v jq >/dev/null 2>&1 || {
	printf 'chronos: jq is required to run this suite\n' >&2
	exit 1
}

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/chronos-codex-test.XXXXXX")
cleanup() {
	case "$TMPROOT" in
	*/chronos-codex-test.*) rm -rf "$TMPROOT" ;;
	esac
}
trap cleanup EXIT

# run STDIN_PAYLOAD [ENV=VAL ...]
# Results land in $RUN_OUT / $RUN_ERR / $RUN_RC. Deliberately NOT via
# `out=$(run ...)`: a command substitution runs the function in a subshell, so
# every variable it set would be discarded the moment it returned.
RUN_OUT=""
RUN_ERR=""
RUN_RC=0
run() {
	local payload="$1"
	shift
	printf '%s' "$payload" |
		env TMPDIR="$TMPROOT" "$@" bash "$SCRIPT" >"$TMPROOT/out" 2>"$TMPROOT/err"
	RUN_RC=$?
	RUN_OUT=$(cat "$TMPROOT/out")
	RUN_ERR=$(cat "$TMPROOT/err")
}

ctx() { printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

PAYLOAD='{"hook_event_name":"UserPromptSubmit","session_id":"s1"}'

# --- 1. emits well-formed hook JSON -------------------------------------------
run "$PAYLOAD"
check "exits 0" "0" "$RUN_RC"
if printf '%s' "$RUN_OUT" | jq -e . >/dev/null 2>&1; then pass; else fail "output is valid JSON" "$RUN_OUT"; fi
check "hookEventName is always UserPromptSubmit" "UserPromptSubmit" \
	"$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.hookEventName // empty')"

# --- 2. the injected line has the documented shape ----------------------------
c=$(ctx)
if printf '%s' "$c" |
	grep -Eq '^Current time: [A-Z][a-z]{2} [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} [A-Za-z0-9+-]+ \(UTC[+-][0-9]{2}:[0-9]{2}\)\.$'; then
	pass
else
	fail "additionalContext matches the documented format" "$c"
fi

# --- 3. the time reported is the real time, in the configured zone ------------
# Compares against date(1) sampled either side of the run, so a minute rollover
# mid-test cannot flake it.
for tz in UTC Asia/Kolkata America/New_York; do
	before=$(TZ="$tz" LC_ALL=C date '+%a %Y-%m-%d %H:%M')
	run "$PAYLOAD" AGENT_PLUGINS_TIME_ZONE="$tz"
	after=$(TZ="$tz" LC_ALL=C date '+%a %Y-%m-%d %H:%M')
	c=$(ctx)
	if [ -n "$c" ] && { [ "${c#Current time: "$before"}" != "$c" ] || [ "${c#Current time: "$after"}" != "$c" ]; }; then
		pass
	else
		fail "clock matches date(1) for $tz" "got [$c] expected prefix [$before] or [$after]"
	fi
done

# --- 4. UTC offset is rendered correctly --------------------------------------
run "$PAYLOAD" AGENT_PLUGINS_TIME_ZONE=UTC
if printf '%s' "$(ctx)" | grep -Fq '(UTC+00:00).'; then pass; else fail "UTC renders +00:00" "$(ctx)"; fi
run "$PAYLOAD" AGENT_PLUGINS_TIME_ZONE=Asia/Kolkata
if printf '%s' "$(ctx)" | grep -Fq '(UTC+05:30).'; then pass; else fail "Asia/Kolkata renders +05:30 (a half-hour zone)" "$(ctx)"; fi

# --- 5. hostile / malformed timezones are refused, and never break the turn ---
#
# SCOPE, verified by mutation: these checks assert the OUTCOME (refused, nothing
# executed, exit 0). They cannot detect removal of the charset guard itself,
# because the zoneinfo existence check refuses the same payloads independently —
# on macOS /usr/share/zoneinfo is a symlink into a versioned path
# (/private/var/db/timezone/tz/<ver>/zoneinfo), so no fixed number of "../"
# segments reaches /etc/passwd, and the depth that would differs per platform and
# per tzdata release. The guard is gated at source level further down instead.
MARKER="$TMPROOT/pwned"
for bad in "../../../etc/passwd" "/etc/passwd" \
	'Asia/Kolkata; touch '"$MARKER" '$(touch '"$MARKER"')' "Not/AZone"; do
	run "$PAYLOAD" AGENT_PLUGINS_TIME_ZONE="$bad"
	label="rejects timezone [$bad]"
	if [ "$RUN_RC" -eq 0 ] && [ -z "$RUN_OUT" ]; then
		pass
	else
		fail "$label — must exit 0 and emit nothing" "rc=$RUN_RC out=[$RUN_OUT]"
	fi
	case "$RUN_ERR" in
	*"invalid AGENT_PLUGINS_TIME_ZONE"*) pass ;;
	*) fail "$label — must explain itself on stderr" "[$RUN_ERR]" ;;
	esac
done
if [ -e "$MARKER" ]; then fail "timezone injection executed a command" "$MARKER exists"; else pass; fi

# An EMPTY value is not hostile — ${VAR:-default} treats it as unset, so it must
# fall back to the default zone and still emit.
run "$PAYLOAD" AGENT_PLUGINS_TIME_ZONE=
check "empty timezone exits 0" "0" "$RUN_RC"
if [ -n "$RUN_OUT" ]; then pass; else fail "empty timezone falls back to the default and still emits" "empty"; fi

# --- 6. degenerate input never breaks the turn ---------------------------------
# The Codex script drains stdin without parsing it, so ANY input must work —
# including none at all, which is what a hook harness that closes stdin gives it.
for label in "empty stdin" "non-JSON stdin" "large stdin"; do
	case "$label" in
	"empty stdin") payload="" ;;
	"non-JSON stdin") payload="not json at all" ;;
	"large stdin") payload=$(head -c 200000 /dev/zero | tr '\0' 'x') ;;
	esac
	run "$payload"
	check "$label exits 0" "0" "$RUN_RC"
	if [ -n "$RUN_OUT" ]; then pass; else fail "$label still emits" "empty"; fi
done

# --- 7. it stays stateless -----------------------------------------------------
# Unlike the Claude script there is no throttle and no session state: two calls in
# a row must both emit, and nothing may be written under TMPDIR.
run "$PAYLOAD"
first="$RUN_OUT"
run "$PAYLOAD"
if [ -n "$first" ] && [ -n "$RUN_OUT" ]; then pass; else fail "consecutive calls both emit (no throttling)" "first=[$first] second=[$RUN_OUT]"; fi
stray=$(find "$TMPROOT" -mindepth 1 -maxdepth 1 ! -name out ! -name err | head -5 | tr '\n' ' ')
check "writes no state under TMPDIR" "" "$stray"

# --- 8. JSON escaping is correct without jq ------------------------------------
# The Codex script hand-rolls its escaper rather than depending on jq. Its only
# variable input is the rendered timestamp, but a zone abbreviation is
# locale-derived, so the output must stay parseable whatever it contains.
run "$PAYLOAD" AGENT_PLUGINS_TIME_ZONE=America/St_Johns
if printf '%s' "$RUN_OUT" | jq -e . >/dev/null 2>&1; then pass; else fail "output stays valid JSON for an unusual zone" "$RUN_OUT"; fi
if printf '%s' "$(ctx)" | grep -Eq '\(UTC-0[23]:30\)\.$'; then pass; else fail "America/St_Johns renders a negative half-hour offset" "$(ctx)"; fi
if grep -Fq 'json_escape' "$SCRIPT"; then pass; else fail "the jq-free escaper is still present" "json_escape not found"; fi

# --- 9. the charset guard exists (source-level, and here is why) ---------------
# Behavioural tests above cannot observe this guard: the zoneinfo existence check
# refuses the same inputs on its own, so removing the guard changes no output on
# this platform. It still matters — it is what keeps a hostile value out of a
# path expression and out of TZ on a system whose zoneinfo root sits at a
# traversable depth. A source assertion is the only honest way to gate it.
if grep -Fq 'case "$timezone" in' "$SCRIPT" &&
	grep -Eq '\*\.\.\*' "$SCRIPT" &&
	grep -Fq '*[!A-Za-z0-9_+./-]*' "$SCRIPT"; then
	pass
else
	fail "timezone charset/traversal guard is present in resolve_timezone" \
		"expected a case arm rejecting empty, absolute, .. and out-of-charset values"
fi

# --- 10. Codex hook wiring -----------------------------------------------------
# Codex ignores prompt/agent-type hooks entirely — a non-command handler here is
# silently dead, not an error. And the plugin root must arrive as "$PLUGIN_ROOT"
# (quoted), never CLAUDE_PLUGIN_ROOT and never a pinned cache path, or the hook
# breaks on the next version bump.
HOOKS="$HERE/../hooks/hooks.json"
if jq -e . "$HOOKS" >/dev/null 2>&1; then pass; else fail "hooks.json is valid JSON" "$HOOKS"; fi
check "every handler is type=command" "" \
	"$(jq -r '[.hooks[]?[]?.hooks[]? | select(.type != "command") | .type] | join(" ")' "$HOOKS" 2>/dev/null)"
check "no handler references CLAUDE_PLUGIN_ROOT" "" \
	"$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty | select(test("CLAUDE_PLUGIN_ROOT"))] | join(" | ")' "$HOOKS" 2>/dev/null)"
check "every command uses a quoted \"\$PLUGIN_ROOT\"" "" \
	"$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty | select(test("\"\\$PLUGIN_ROOT/") | not)] | join(" | ")' "$HOOKS" 2>/dev/null)"
check "no command pins a version cache path" "" \
	"$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty | select(test("plugins/cache"))] | join(" | ")' "$HOOKS" 2>/dev/null)"

printf 'chronos tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
