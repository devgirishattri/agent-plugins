#!/usr/bin/env bash
# Functional gate for chronos (Claude tree).
#
# chronos is hook-only — no commands, no skills — so it was invisible to every
# per-plugin test gate until this suite existed: a `test-*.sh` glob found nothing
# to run and reported success. What it emits is injected into every turn, and a
# silent failure (bad JSON, a wrong timezone, a hook that exits non-zero) either
# corrupts context or breaks the turn, so it is worth a real gate.
#
# Accumulating, not fail-fast: every check runs and the suite reports
# "<passed> passed, <failed> failed", so one broken assertion cannot hide the
# results of the ones after it.
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

# Private state root: the script keeps per-session throttle state under
# $XDG_RUNTIME_DIR/chronos (falling back to XDG_CACHE_HOME, then ~/.cache).
# Pointing XDG_RUNTIME_DIR at a scratch dir keeps the suite from reading and
# WRITING the real state directory, which could throttle a live session's next
# injection. TMPDIR is pointed there too so nothing leaks into the shared tmp.
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/chronos-test.XXXXXX")
cleanup() {
	case "$TMPROOT" in
	*/chronos-test.*) rm -rf "$TMPROOT" ;;
	esac
}
trap cleanup EXIT

# run EVENT SESSION_ID [ENV=VAL ...]
# Results land in $RUN_OUT / $RUN_ERR / $RUN_RC. Deliberately NOT via
# `out=$(run ...)`: a command substitution runs the function in a subshell, so
# every variable it set would be discarded the moment it returned.
RUN_OUT=""
RUN_ERR=""
RUN_RC=0
run() {
	local event="$1" session="$2"
	shift 2
	local payload
	payload=$(jq -cn --arg e "$event" --arg s "$session" \
		'{hook_event_name: $e, session_id: $s}')
	printf '%s' "$payload" |
		env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" "$@" bash "$SCRIPT" >"$TMPROOT/out" 2>"$TMPROOT/err"
	RUN_RC=$?
	RUN_OUT=$(cat "$TMPROOT/out")
	RUN_ERR=$(cat "$TMPROOT/err")
}

ctx() { printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null; }

# --- 1. emits well-formed hook JSON on UserPromptSubmit -----------------------
run UserPromptSubmit s1
check "UserPromptSubmit exits 0" "0" "$RUN_RC"
if printf '%s' "$RUN_OUT" | jq -e . >/dev/null 2>&1; then pass; else fail "output is valid JSON" "$RUN_OUT"; fi
check "hookEventName echoes the input event" "UserPromptSubmit" \
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
# Guards against a plausible-looking but wrong clock: compare against date(1)
# sampled either side of the run, so a minute rollover mid-test cannot flake.
for tz in UTC Asia/Kolkata America/New_York; do
	before=$(TZ="$tz" LC_ALL=C date '+%a %Y-%m-%d %H:%M')
	run UserPromptSubmit "clock-$tz" AGENT_PLUGINS_TIME_ZONE="$tz"
	after=$(TZ="$tz" LC_ALL=C date '+%a %Y-%m-%d %H:%M')
	c=$(ctx)
	if [ -n "$c" ] && { [ "${c#Current time: "$before"}" != "$c" ] || [ "${c#Current time: "$after"}" != "$c" ]; }; then
		pass
	else
		fail "clock matches date(1) for $tz" "got [$c] expected prefix [$before] or [$after]"
	fi
done

# --- 4. UTC offset is rendered correctly --------------------------------------
run UserPromptSubmit off-utc AGENT_PLUGINS_TIME_ZONE=UTC
if printf '%s' "$(ctx)" | grep -Fq '(UTC+00:00).'; then pass; else fail "UTC renders +00:00" "$(ctx)"; fi
run UserPromptSubmit off-ist AGENT_PLUGINS_TIME_ZONE=Asia/Kolkata
if printf '%s' "$(ctx)" | grep -Fq '(UTC+05:30).'; then pass; else fail "Asia/Kolkata renders +05:30 (a half-hour zone)" "$(ctx)"; fi

# --- 5. hostile / malformed timezones are refused, and never break the turn ---
# The value reaches TZ and a zoneinfo path lookup, so traversal and shell
# metacharacters must be rejected by the charset guard rather than resolved.
#
# SCOPE, verified by mutation: these checks assert the OUTCOME (refused, nothing
# executed, exit 0). They cannot detect removal of the charset guard itself,
# because the zoneinfo existence check refuses the same payloads independently —
# on macOS /usr/share/zoneinfo is a symlink into a versioned path
# (/private/var/db/timezone/tz/<ver>/zoneinfo), so no fixed number of "../"
# segments reaches /etc/passwd, and the depth that would differs per platform and
# per tzdata release. The guard is defense-in-depth behind that check, so it is
# gated at source level further down instead of pretending a behavioural test
# covers it.
MARKER="$TMPROOT/pwned"
for bad in "../../../etc/passwd" "../../etc/passwd" "/etc/passwd" \
	'Asia/Kolkata; touch '"$MARKER" '$(touch '"$MARKER"')' "Not/AZone"; do
	run UserPromptSubmit "bad-tz" AGENT_PLUGINS_TIME_ZONE="$bad"
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
# fall back to the default zone and still emit. (Asserted explicitly because the
# unreachable "" arm in the script's charset guard suggests otherwise.)
run UserPromptSubmit empty-tz AGENT_PLUGINS_TIME_ZONE=
check "empty timezone exits 0" "0" "$RUN_RC"
if [ -n "$RUN_OUT" ]; then pass; else fail "empty timezone falls back to the default and still emits" "empty"; fi

# --- 6. PreToolUse throttling --------------------------------------------------
# Long autonomous turns must stay time-aware without a timestamp per tool call.
run PreToolUse throttle-a
if [ -n "$RUN_OUT" ]; then pass; else fail "first PreToolUse emits" "empty"; fi
check "PreToolUse echoes its own event name" "PreToolUse" \
	"$(printf '%s' "$RUN_OUT" | jq -r '.hookSpecificOutput.hookEventName // empty')"
run PreToolUse throttle-a
if [ -z "$RUN_OUT" ]; then pass; else fail "second PreToolUse within the interval is throttled" "$RUN_OUT"; fi

# throttle state is per session, not global
run PreToolUse throttle-b
if [ -n "$RUN_OUT" ]; then pass; else fail "a different session is not throttled by the first" "empty"; fi

# UserPromptSubmit is never throttled — every prompt gets a fresh timestamp
run UserPromptSubmit throttle-a
if [ -n "$RUN_OUT" ]; then pass; else fail "UserPromptSubmit is never throttled" "empty"; fi

# --- 7. CHRONOS_INTERVAL_MIN ---------------------------------------------------
run PreToolUse interval-zero CHRONOS_INTERVAL_MIN=0
run PreToolUse interval-zero CHRONOS_INTERVAL_MIN=0
if [ -n "$RUN_OUT" ]; then pass; else fail "CHRONOS_INTERVAL_MIN=0 disables throttling" "empty"; fi

# a non-numeric interval must fall back to the 5-minute default, not to 0
run PreToolUse interval-bad CHRONOS_INTERVAL_MIN=not-a-number
run PreToolUse interval-bad CHRONOS_INTERVAL_MIN=not-a-number
if [ -z "$RUN_OUT" ]; then pass; else fail "a non-numeric CHRONOS_INTERVAL_MIN falls back to the default" "$RUN_OUT"; fi

# --- 8. degenerate input never breaks the turn ---------------------------------
out=$(printf '' | env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" bash "$SCRIPT" 2>/dev/null)
rc=$?
check "empty stdin exits 0" "0" "$rc"
if [ -n "$out" ]; then pass; else fail "empty stdin still emits (defaults to UserPromptSubmit)" "empty"; fi

out=$(printf 'not json at all' | env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" bash "$SCRIPT" 2>/dev/null)
rc=$?
check "non-JSON stdin exits 0" "0" "$rc"
if [ -n "$out" ]; then pass; else fail "non-JSON stdin still emits" "empty"; fi

# --- 9. state is written where XDG_RUNTIME_DIR points, never to the real dir --
if [ -d "$TMPROOT/xdg/chronos" ]; then
	pass
else
	fail "throttle state honours XDG_RUNTIME_DIR" "no chronos state dir under $TMPROOT/xdg"
fi
if [ ! -e "$TMPROOT/chronos-${USER:-$(id -u)}" ]; then
	pass
else
	fail "no state is written under the shared temp root any more" "$TMPROOT/chronos-* exists"
fi

# --- 10. the no-jq fallback still emits parseable JSON -------------------------
# The script has a printf branch for when jq is absent. /usr/bin:/bin carries
# every other binary it needs, so this exercises the branch without the
# sanitized-PATH trap of stripping the interpreter itself.
if PATH=/usr/bin:/bin command -v jq >/dev/null 2>&1; then
	printf 'SKIP: jq is present in /usr/bin:/bin; cannot exercise the no-jq branch\n' >&2
else
	out=$(printf '{"hook_event_name":"UserPromptSubmit","session_id":"nojq"}' |
		env -i PATH=/usr/bin:/bin TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" HOME="$TMPROOT" bash "$SCRIPT" 2>/dev/null)
	rc=$?
	check "no-jq fallback exits 0" "0" "$rc"
	if printf '%s' "$out" | jq -e . >/dev/null 2>&1; then
		pass
	else
		fail "no-jq fallback still emits valid JSON" "$out"
	fi
fi

# --- 11. the charset guard exists (source-level, and here is why) --------------
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

# --- 12. hook wiring -----------------------------------------------------------
HOOKS="$HERE/../hooks/hooks.json"
if jq -e . "$HOOKS" >/dev/null 2>&1; then pass; else fail "hooks.json is valid JSON" "$HOOKS"; fi
# every command must reference the plugin root variable, never a pinned cache path
bad=$(jq -r '[.hooks[]?[]?.hooks[]?.command // empty] | map(select(test("CLAUDE_PLUGIN_ROOT") | not)) | join(" | ")' "$HOOKS" 2>/dev/null)
check "every hook command goes through \${CLAUDE_PLUGIN_ROOT}" "" "$bad"

# --- 13. cross-session PreToolUse throttling never leaks between sessions -----
run PreToolUse cross-a
if [ -n "$RUN_OUT" ]; then pass; else fail "cross-a first PreToolUse emits" "empty"; fi
run PreToolUse cross-b
if [ -n "$RUN_OUT" ]; then pass; else fail "cross-b first PreToolUse emits (not suppressed by cross-a)" "empty"; fi
run PreToolUse cross-a
if [ -z "$RUN_OUT" ]; then pass; else fail "cross-a second call within the interval is throttled" "$RUN_OUT"; fi
run PreToolUse cross-b
if [ -z "$RUN_OUT" ]; then pass; else fail "cross-b second call within the interval is throttled" "$RUN_OUT"; fi

# --- 14. jq parses structurally: key order and nested/escaped text never win --
# (a) tool_input carries its own session_id/hook_event_name BEFORE the real
# top-level keys in the serialized object. A textual/positional scan could be
# fooled; jq's `.session_id`/`.hook_event_name` cannot be, because they only
# ever address the top level regardless of where in the byte stream it sits.
top_session_a="top-real-a"
payload_a=$(jq -cn --arg top "$top_session_a" \
	'{tool_input: {session_id: "nested-x", hook_event_name: "UserPromptSubmit"}, hook_event_name: "PreToolUse", session_id: $top}')
printf '%s' "$payload_a" | env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" bash "$SCRIPT" >"$TMPROOT/out" 2>"$TMPROOT/err"
rc=$?
check "reordered/nested payload exits 0" "0" "$rc"
check "top-level hook_event_name wins over a nested one" "PreToolUse" \
	"$(printf '%s' "$(cat "$TMPROOT/out")" | jq -r '.hookSpecificOutput.hookEventName // empty')"
if [ -f "$TMPROOT/xdg/chronos/last-$top_session_a" ]; then
	pass
else
	fail "top-level session_id wins over a nested tool_input.session_id" \
		"expected state file last-$top_session_a"
fi
if [ -f "$TMPROOT/xdg/chronos/last-nested-x" ]; then
	fail "the nested session_id must never be used for state" "last-nested-x exists"
else
	pass
fi

# (b) an escaped `"session_id":"fake"` string sitting inside a tool argument's
# value must not be mistaken for a real key.
top_session_b="top-real-b"
payload_b=$(jq -cn --arg top "$top_session_b" \
	'{hook_event_name: "PreToolUse", session_id: $top, tool_input: {command: "echo \"session_id\":\"fake\""}}')
printf '%s' "$payload_b" | env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" bash "$SCRIPT" >"$TMPROOT/out" 2>"$TMPROOT/err"
rc=$?
check "escaped-text payload exits 0" "0" "$rc"
if [ -f "$TMPROOT/xdg/chronos/last-$top_session_b" ]; then
	pass
else
	fail "top-level session_id wins over escaped text inside a tool argument" \
		"expected state file last-$top_session_b"
fi
if [ -f "$TMPROOT/xdg/chronos/last-fake" ]; then
	fail "escaped session_id-shaped text inside a value must never be used" "last-fake exists"
else
	pass
fi

# (c) malformed JSON still exits 0 and falls back to today's defaults
# (UserPromptSubmit, last-default) rather than breaking the turn.
malformed='{"hook_event_name":"PreToolUse", "session_id":'
out=$(printf '%s' "$malformed" | env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" bash "$SCRIPT" 2>"$TMPROOT/err")
rc=$?
check "malformed JSON exits 0" "0" "$rc"
check "malformed JSON falls back to the default event" "UserPromptSubmit" \
	"$(printf '%s' "$out" | jq -r '.hookSpecificOutput.hookEventName // empty')"
if [ -f "$TMPROOT/xdg/chronos/last-default" ]; then
	pass
else
	fail "malformed JSON falls back to the default state file" "no last-default state file"
fi

# --- 15. control: jq hidden AND there is no session_id to read at all ---------
mkdir -p "$TMPROOT/nojqbin"
for bin in date cat mkdir; do
	ln -sf "$(command -v "$bin")" "$TMPROOT/nojqbin/$bin"
done
if ( hash -r; PATH="$TMPROOT/nojqbin" command -v jq >/dev/null 2>&1 ); then
	fail "control setup: jq unexpectedly reachable on the stripped PATH" ""
else
	out=$(printf '{"hook_event_name":"PreToolUse"}' |
		env PATH="$TMPROOT/nojqbin" TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg" "$(command -v bash)" "$SCRIPT" 2>"$TMPROOT/err")
	rc=$?
	check "jq-hidden, no-session_id control exits 0" "0" "$rc"
	if [ -n "$out" ]; then pass; else fail "jq-hidden control still emits" "empty"; fi
	if [ -f "$TMPROOT/xdg/chronos/last-default" ]; then
		pass
	else
		fail "jq-hidden control uses the default state file" "no last-default state file"
	fi
fi

# --- 16. security: the state write must never follow a planted symlink --------
# Attack model: another local user pre-creates the (old, predictable) state
# directory and plants a symlink where the per-session state file goes. Both
# the legacy location ($TMPDIR/chronos-$USER) and the current location are
# seeded so the assertion holds against either layout.
victim="$TMPROOT/victim.txt"
printf 'keep' >"$victim"
mkdir -p "$TMPROOT/chronos-${USER:-$(id -u)}" "$TMPROOT/xdg/chronos"
ln -s "$victim" "$TMPROOT/chronos-${USER:-$(id -u)}/last-sym-a"
ln -s "$victim" "$TMPROOT/xdg/chronos/last-sym-a"
run UserPromptSubmit sym-a
check "planted-symlink run still exits 0" "0" "$RUN_RC"
if [ -n "$(ctx)" ]; then pass; else fail "planted-symlink run still emits context" "empty"; fi
check "planted symlink is never followed (victim intact)" "keep" "$(cat "$victim")"
if [ -L "$TMPROOT/xdg/chronos/last-sym-a" ]; then
	pass
else
	fail "planted symlink is left in place, not replaced or removed" "state entry changed type"
fi
# a state DIRECTORY that is itself a symlink is refused too
mkdir -p "$TMPROOT/elsewhere"
rm -rf "$TMPROOT/xdg2" && mkdir -p "$TMPROOT/xdg2" && ln -s "$TMPROOT/elsewhere" "$TMPROOT/xdg2/chronos"
payload=$(jq -cn '{hook_event_name:"UserPromptSubmit", session_id:"sym-dir"}')
printf '%s' "$payload" | env TMPDIR="$TMPROOT" XDG_RUNTIME_DIR="$TMPROOT/xdg2" bash "$SCRIPT" >"$TMPROOT/out" 2>/dev/null
check "symlinked state dir run still exits 0" "0" "$?"
if [ ! -e "$TMPROOT/elsewhere/last-sym-dir" ]; then
	pass
else
	fail "symlinked state dir is refused (nothing written through it)" "last-sym-dir written into the link target"
fi
# control: an ordinary session on the same root gets a real 0700 dir and a digit-only file
run UserPromptSubmit ctrl-a
check "control run exits 0" "0" "$RUN_RC"
if [ -f "$TMPROOT/xdg/chronos/last-ctrl-a" ] && [ ! -L "$TMPROOT/xdg/chronos/last-ctrl-a" ]; then
	pass
else
	fail "control writes a regular state file" "missing or not a regular file"
fi
case "$(cat "$TMPROOT/xdg/chronos/last-ctrl-a")" in
	*[!0-9]*|'') fail "control state file holds an epoch" "$(cat "$TMPROOT/xdg/chronos/last-ctrl-a")" ;;
	*) pass ;;
esac
# Explicit platform branch: GNU stat first (`-c`), BSD (`-f`) otherwise. A
# BSD-first fallback is not Linux-safe: GNU `stat -f` is a filesystem report.
if stat -c '%a' / >/dev/null 2>&1; then
	mode=$(stat -c '%a' "$TMPROOT/xdg/chronos")
else
	mode=$(stat -f '%Lp' "$TMPROOT/xdg/chronos")
fi
check "control state dir is owner-only (0700)" "700" "$mode"
run PreToolUse ctrl-a
check "control throttle: PreToolUse inside the window emits nothing" "" "$(ctx)"
printf '0' >"$TMPROOT/xdg/chronos/last-ctrl-a"
run PreToolUse ctrl-a
if [ -n "$(ctx)" ]; then pass; else fail "control throttle: PreToolUse after the window emits" "empty"; fi

printf 'chronos tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
