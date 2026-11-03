#!/usr/bin/env bash
# Contract and runtime gate for session-walkthrough.
#
# The plugin has one mode, the live tour: an overlay injected into the app in
# the already-running browser. This suite checks the plugin manifest and the
# skill frontmatter, that the skill and its reference link only to files that
# exist, that shipped files carry no machine paths, the overlay's node:test
# suite (each node test counts as one check), and that the skill routes every
# walkthrough request to the live tour and names no removed recorded-bundle
# helper. Every negative assertion has a positive control.
#
# Accumulating, not fail-fast: every check runs and the suite reports
# "<passed> passed, <failed> failed".
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)

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

command -v python3 >/dev/null 2>&1 || {
	printf 'session-walkthrough: python3 is required to run this suite\n' >&2
	exit 1
}

# --- 1. manifest -----------------------------------------------------------
# Provider-neutral: the Codex twin ships .codex-plugin/plugin.json, the Claude
# tree .claude-plugin/plugin.json. The suite is mirrored byte-identically.
if [ -f "$PLUGIN/.codex-plugin/plugin.json" ]; then
	MANIFEST="$PLUGIN/.codex-plugin/plugin.json"
else
	MANIFEST="$PLUGIN/.claude-plugin/plugin.json"
fi
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$MANIFEST" 2>/dev/null; then pass; else fail "plugin.json is valid JSON"; fi
check "plugin name" "session-walkthrough" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$MANIFEST")"
check "plugin license" "MIT" "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["license"])' "$MANIFEST")"
if python3 -c 'import json,re,sys; v=json.load(open(sys.argv[1]))["version"]; sys.exit(0 if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", v) else 1)' "$MANIFEST"; then pass; else fail "plugin version is semver"; fi

# --- 2. skill frontmatter ----------------------------------------------------
SKILL="$PLUGIN/skills/session-walkthrough/SKILL.md"
out=$(python3 - "$SKILL" <<'PY'
import sys, pathlib
path = pathlib.Path(sys.argv[1])
lines = path.read_text(encoding="utf-8").splitlines()
problems = []
if not lines or lines[0] != "---":
    problems.append("missing frontmatter")
else:
    try:
        end = lines.index("---", 1)
    except ValueError:
        problems.append("unterminated frontmatter"); end = 1
    fm = {}
    for line in lines[1:end]:
        key, _, value = line.partition(":")
        fm[key.strip()] = value.strip()
        if ": " in value.strip() and not value.strip().startswith(('"', "'")):
            problems.append(f"unquoted ': ' in {key}")
    if fm.get("name") != path.parent.name:
        problems.append(f"name {fm.get('name')!r} != directory {path.parent.name!r}")
    if not fm.get("description"):
        problems.append("empty description")
print("\n".join(problems))
PY
)
check "SKILL.md frontmatter is well-formed and names its directory" "" "$out"

# --- 3. documentation links resolve ---------------------------------------------
out=$(python3 - "$PLUGIN/skills/session-walkthrough" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1]); problems = []
for md in [root / "SKILL.md", *sorted((root / "references").glob("*.md"))]:
    for target in re.findall(r"\]\(([^)#]+)\)", md.read_text(encoding="utf-8")):
        if "://" in target:
            continue
        if not (md.parent / target).is_file():
            problems.append(f"{md.relative_to(root)}: broken link {target}")
print("\n".join(problems))
PY
)
check "SKILL.md and references link only to files that exist" "" "$out"

# --- 4. portability: no machine paths in shipped files --------------------------
# The suite excludes itself: this pattern would otherwise match its own source.
home_hits=$(grep -rIl -E '/Users/|/home/[a-z]' --exclude="$(basename "$0")" "$PLUGIN" 2>/dev/null | head -3)
check "shipped files contain no machine-specific home path" "" "$home_hits"

# --- 5. live tour: overlay runtime, demo fixture and skill routing ------------
# The overlay is plain JavaScript checked with node:test (no dependencies). Each
# node test counts as one check here; a missing node is a failure, not a skip.
TOUR_TESTS="$HERE/tour/tests/overlay.test.js"
if command -v node >/dev/null 2>&1; then
	# Pin the TAP reporter: node picks the spec reporter in some environments (CI).
	TOUR_OUT=$(node --test --test-reporter=tap "$TOUR_TESTS" 2>&1)
	TOUR_RC=$?
	TOUR_PASS=$(printf '%s\n' "$TOUR_OUT" | sed -n 's/^# pass \([0-9][0-9]*\)$/\1/p' | tail -n 1)
	TOUR_FAIL=$(printf '%s\n' "$TOUR_OUT" | sed -n 's/^# fail \([0-9][0-9]*\)$/\1/p' | tail -n 1)
	if [ -n "$TOUR_PASS" ] && [ "$TOUR_PASS" -gt 0 ]; then PASS=$((PASS + TOUR_PASS)); else fail "overlay node tests reported no passes" "$(printf '%s' "$TOUR_OUT" | tail -n 5)"; fi
	if [ "${TOUR_FAIL:-1}" != "0" ] || [ "$TOUR_RC" -ne 0 ]; then
		fail "overlay node tests: ${TOUR_FAIL:-unknown} failed (exit $TOUR_RC)" "$(printf '%s\n' "$TOUR_OUT" | grep -E '^not ok' | head -n 5)"
	fi
else
	fail "node is required for the live tour overlay tests"
fi
for shipped in "$HERE/tour/overlay.js" "$PLUGIN/examples/live-tour/demo.html" "$PLUGIN/examples/live-tour/demo-tour.js" \
	"$PLUGIN/examples/live-tour/README.md" "$PLUGIN/skills/session-walkthrough/references/live-tour.md"; do
	if [ -f "$shipped" ]; then pass; else fail "live tour file is shipped: ${shipped#"$PLUGIN"/}"; fi
done
out=$(python3 - "$PLUGIN/skills/session-walkthrough/SKILL.md" "$PLUGIN/skills/session-walkthrough/references/live-tour.md" "$MANIFEST" <<'PY'
import os, re, sys
skill = open(sys.argv[1], encoding="utf-8").read()
tour = open(sys.argv[2], encoding="utf-8").read()
codex = os.path.basename(os.path.dirname(sys.argv[3])) == ".codex-plugin"
problems = []
description = re.search(r"^description:(.*)$", skill, re.M).group(1).lower()
for word in ("walkthrough", "live", "tour", '"walk me through"', '"show me the changes"', "/session-walkthrough"):
    if word not in description:
        problems.append("description lacks %r" % word)
for word in ("bundle", "manifest", "provenance", "explicit request"):
    if word in description:
        problems.append("description still routes to the removed recorded bundle (%r)" % word)
for heading in ("## Modes", "## Recorded bundle", "## Helpers", "## Contracts", "## Tunables"):
    if heading in skill:
        problems.append("SKILL.md still has the bundle-era section %s" % heading)
for phrase in ('"walk me through"', "references/live-tour.md", "examples/live-tour/", "scripts/tour/overlay.js",
               "offers only the live tour", "devicePixelRatio", "emulate", "resize_page", "new_page"):
    if phrase not in skill:
        problems.append("SKILL.md lacks %s" % phrase)
# Claude skills expand ${CLAUDE_PLUGIN_ROOT}; Codex skills substitute the installed root for <PLUGIN_ROOT>.
root = "<PLUGIN_ROOT>" if codex else "${CLAUDE_PLUGIN_ROOT}"
for path in ("/scripts/tour/overlay.js", "/examples/live-tour/"):
    if root + path not in skill:
        problems.append("SKILL.md does not give %s%s" % (root, path))
if codex and "CLAUDE_PLUGIN_ROOT" in skill:
    problems.append("Codex SKILL.md names ${CLAUDE_PLUGIN_ROOT}")
for phrase in ("evaluate_script", "getBoundingClientRect", "sessionStorage", "setInterval", "Design decision", "Not shown", "__vue__", "resize_page", "new_page"):
    if phrase not in tour:
        problems.append("live-tour.md lacks %s" % phrase)
print("\n".join(problems))
PY
)
check "SKILL.md routes every walkthrough request to the live tour" "" "$out"

# --- 6. the recorded bundle is gone ------------------------------------------------
# The recorded-bundle mode (validator, renderer, scope helper, schemas, fixtures
# and their references) was removed. No shipped file may name it, so a merge that
# brings part of it back fails here. The suite excludes itself: it names the
# patterns.
out=$(python3 - "$PLUGIN" "$(basename "$0")" <<'PY'
import os, re, sys
plugin, suite = sys.argv[1], sys.argv[2]
REMOVED = re.compile(
    r"(?<![\w-])walkthrough\.(?:sh|py)\b"
    r"|\b(?:manifest|descriptor)\.schema\.json\b"
    r"|\bSESSION_WALKTHROUGH_[A-Z_]+"
    r"|\bWT-[A-Z]"
    r"|references/(?:adapters|manifest|output|receipts|workspace-integration)\.md"
    r"|\.tmp/walkthroughs"
    r"|## Recorded bundle")


def hits(text):
    return [m.group(0) for m in REMOVED.finditer(text)]


problems = []
if not hits('bash "${CLAUDE_PLUGIN_ROOT}/scripts/walkthrough.sh" validate --manifest manifest.json'):
    problems.append("control: the scan does not flag a walkthrough.sh invocation")
if not hits("see references/receipts.md and SESSION_WALKTHROUGH_OUTPUT_ROOT"):
    problems.append("control: the scan does not flag a bundle reference or tunable")
if hits("bash scripts/test-session-walkthrough.sh") or hits("SessionWalkthroughTour.goTo(i)"):
    problems.append("control: the scan flags the suite name or the tour API")
for gone in ("scripts/walkthrough.sh", "scripts/walkthrough.py", "scripts/manifest.schema.json",
             "scripts/descriptor.schema.json", "scripts/descriptors", "scripts/fixtures"):
    if os.path.exists(os.path.join(plugin, gone)):
        problems.append("removed bundle path is shipped again: %s" % gone)
for base, dirs, files in os.walk(plugin):
    for name in files:
        if name == suite:
            continue
        path = os.path.join(base, name)
        try:
            text = open(path, encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        found = hits(text)
        if found:
            problems.append("%s names the removed bundle: %s" % (os.path.relpath(path, plugin), ", ".join(sorted(set(found)))))
print("\n".join(problems))
PY
)
check "no shipped file names the removed recorded bundle" "" "$out"

printf 'session-walkthrough tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
