#!/usr/bin/env bash
# Contract and runtime gate for session-walkthrough (Claude tree).
#
# Sections 1-7 (Stage 1) prove the shipped contract artifacts are internally
# consistent: closed schemas, descriptors that match their ids and the adapters
# reference, a fixture index whose expected codes exist in the manifest
# reference, valid fixtures whose asset hashes and scope fingerprints recompute,
# and negatives that really differ from their controls.
#
# Sections 8-14 (Stage 2) run the helper through walkthrough.sh: the validator
# against every fixture (exit code and WT-* codes), the renderer's safety and
# disclosure properties, the scope helper in throwaway git repositories,
# containment, the run-directory lock, run-directory mode, and the dispatcher
# and skill invocation idiom. Every negative assertion has a positive control.
# Write containment holds for render whether or not --manifest is given, so every
# render runs in a run directory inside a throwaway repository. Run-directory
# mode re-derives the committed history (section 13b), and render and scope
# read and re-check only while they hold the run lock (section 12d).
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

# --- 3. schemas are closed ------------------------------------------------------
for schema in manifest.schema.json descriptor.schema.json; do
	out=$(python3 - "$HERE/$schema" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
problems = []
if doc.get("$schema") != "http://json-schema.org/draft-07/schema#":
    problems.append("not draft-07")
def walk(node, path):
    if isinstance(node, dict):
        if node.get("type") == "object" and "additionalProperties" not in node and "properties" in node:
            problems.append(f"open object at {path}")
        for k, v in node.items():
            walk(v, f"{path}/{k}")
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, f"{path}[{i}]")
walk(doc, "")
# additionalProperties as a schema (tool_versions) is allowed; false elsewhere
print("\n".join(problems))
PY
)
	check "$schema is draft-07 with every object closed" "" "$out"
done

# --- 4. descriptors ---------------------------------------------------------
ADAPTERS_DOC="$PLUGIN/skills/session-walkthrough/references/adapters.md"
out=$(python3 - "$HERE" "$ADAPTERS_DOC" <<'PY'
import json, pathlib, re, sys
here = pathlib.Path(sys.argv[1]); doc = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
schema = json.load(open(here / "descriptor.schema.json"))
problems = []
files = sorted((here / "descriptors").glob("*.json"))
if not files:
    problems.append("no descriptors shipped")
for path in files:
    d = json.load(open(path))
    label = path.name
    if d.get("id") != path.stem:
        problems.append(f"{label}: id != file stem")
    if d.get("schema_version") != 1:
        problems.append(f"{label}: schema_version != 1")
    missing = set(schema["required"]) - set(d)
    unknown = set(d) - set(schema["properties"])
    if missing: problems.append(f"{label}: missing {sorted(missing)}")
    if unknown: problems.append(f"{label}: unknown {sorted(unknown)}")
    if d.get("probe", {}).get("reads_only") is not True:
        problems.append(f"{label}: probe.reads_only must be true")
    for token in d.get("probe", {}).get("argv", []):
        if not re.fullmatch(r"[A-Za-z0-9_./=-]{1,80}", token):
            problems.append(f"{label}: unsafe probe token {token!r}")
    if d.get("probe", {}).get("kind") == "none" and d.get("probe", {}).get("argv"):
        problems.append(f"{label}: probe kind none with argv")
    if d.get("recording", {}).get("max_duration_seconds", 999) > 180:
        problems.append(f"{label}: max_duration_seconds > 180")
    pilot = d.get("pilot", {})
    if pilot.get("recorded") and not pilot.get("host"):
        problems.append(f"{label}: recorded pilot without host")
    if pilot.get("recorded"):
        problems.append(f"{label}: 0.1.0 may not claim a recorded pilot")
    for opt in d.get("egress", {}).get("opt_outs", []):
        if opt.get("status") not in ("researched", "verified"):
            problems.append(f"{label}: opt-out status {opt.get('status')!r}")
    if f"| `{d.get('id')}` |" not in doc:
        problems.append(f"{label}: not listed in adapters.md")
    for kind in d.get("recording", {}).get("kinds", []):
        if kind not in ("stills", "continuous", "frame-sampled"):
            problems.append(f"{label}: unknown recording kind {kind}")
print("\n".join(problems))
PY
)
check "descriptors match their ids, the schema's field set, and adapters.md" "" "$out"

# --- 5. fixture index and manifests -------------------------------------------
FIX="$HERE/fixtures"
MANIFEST_DOC="$PLUGIN/skills/session-walkthrough/references/manifest.md"
out=$(python3 - "$FIX" "$MANIFEST_DOC" "$HERE/descriptors" "$HERE/manifest.schema.json" <<'PY'
import hashlib, json, pathlib, re, sys
fix = pathlib.Path(sys.argv[1]); doc = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
descriptors = {p.stem for p in pathlib.Path(sys.argv[3]).glob("*.json")}
schema = json.load(open(sys.argv[4]))
problems = []
documented = set(re.findall(r"`(WT-[A-Z-]+)`", doc))
index = json.load(open(fix / "manifests/index.json"))
cases = index["cases"]
on_disk = {p.name for p in (fix / "manifests").glob("*.json")} - {"index.json"}
if set(cases) != on_disk:
    problems.append(f"index/disk mismatch: only-index={sorted(set(cases)-on_disk)} only-disk={sorted(on_disk-set(cases))}")
run_dir = (fix / "manifests" / index["run_dir"]).resolve()
if not run_dir.is_dir():
    problems.append("index.run_dir does not resolve")

def dup_hook(pairs):
    seen = {}
    for k, v in pairs:
        if k in seen:
            raise ValueError(f"duplicate key {k}")
        seen[k] = v
    return seen

def fingerprint(entries):
    canon = json.dumps(sorted(entries, key=lambda e: e["path"]), sort_keys=True,
                       separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canon.encode()).hexdigest()

valid_names = {n for n, c in cases.items() if c["expect"] == "valid"}
for name, case in cases.items():
    path = fix / "manifests" / name
    text = path.read_text(encoding="utf-8")
    expect = case["expect"]
    if expect == "valid":
        if case.get("control") is not None:
            problems.append(f"{name}: valid case must have control null")
    else:
        codes = expect.get("invalid") if isinstance(expect, dict) else None
        if not codes:
            problems.append(f"{name}: invalid case lists no codes"); codes = []
        for code in codes:
            if code not in documented:
                problems.append(f"{name}: code {code} not documented in manifest.md")
        control = case.get("control")
        if control not in valid_names:
            problems.append(f"{name}: control {control!r} is not a valid case")
        elif (fix / "manifests" / control).read_bytes() == path.read_bytes():
            problems.append(f"{name}: identical to its control; mutation missing")
    # Duplicate-key fixture must be rejected by the hook and accepted by plain parsing.
    try:
        parsed = json.loads(text, object_pairs_hook=dup_hook)
        if name == "duplicate-json-key.json":
            problems.append(f"{name}: duplicate key not present")
    except ValueError:
        parsed = None
        if name != "duplicate-json-key.json":
            problems.append(f"{name}: duplicate key in a fixture that should parse")
        elif json.loads(text) is None:
            problems.append(f"{name}: plain parse should still succeed")
    if parsed is None or expect != "valid":
        continue
    # Valid controls: closed top-level shape, consistent hashes and fingerprints.
    if set(parsed) != set(schema["required"]):
        problems.append(f"{name}: top-level keys != schema required set")
    if parsed.get("schema_version") != 1:
        problems.append(f"{name}: schema_version != 1")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]{3,63}", parsed["run"]["id"]):
        problems.append(f"{name}: run.id grammar")
    if parsed["target"]["adapter"] not in descriptors:
        problems.append(f"{name}: unknown target adapter")
    seen_paths = set()
    for asset in parsed["assets"]:
        if asset["tool"]["adapter"] not in descriptors:
            problems.append(f"{name}: asset {asset['id']} unknown adapter")
        if not re.fullmatch(r"assets/[A-Za-z0-9][A-Za-z0-9._-]{0,99}\.(png|jpg|jpeg|webp|mp4|mov|webm)", asset["path"]):
            problems.append(f"{name}: asset path grammar {asset['path']}")
            continue
        if asset["path"] in seen_paths:
            problems.append(f"{name}: duplicate asset path {asset['path']}")
        seen_paths.add(asset["path"])
        file = run_dir / asset["path"]
        if not file.is_file() or file.is_symlink():
            problems.append(f"{name}: asset file missing {asset['path']}"); continue
        data = file.read_bytes()
        if hashlib.sha256(data).hexdigest() != asset["sha256"] or len(data) != asset["bytes"]:
            problems.append(f"{name}: asset hash/size mismatch {asset['path']}")
        signature_ok = {"image/png": data.startswith(b"\x89PNG\r\n\x1a\n"),
                        "video/mp4": data[4:8] == b"ftyp", "video/quicktime": data[4:8] == b"ftyp"}
        if not signature_ok.get(asset["media_type"], True):
            problems.append(f"{name}: asset signature mismatch {asset['path']}")
    for key in ("start", "end"):
        snap = parsed["scope"][key]
        if snap is None:
            continue
        if fingerprint(snap["entries"]) != snap["fingerprint"]:
            problems.append(f"{name}: scope.{key}.fingerprint does not recompute")
    # Freshness per references/receipts.md "Derived freshness" (order 1-5) and unbound paths.
    receipt = parsed["build"]["receipt"]; target = parsed["target"]; end = parsed["scope"]["end"]
    binding_keys = {"macos": ("bundle_id",), "ios-simulator": ("udid", "bundle_id"),
                    "android-emulator": ("device", "bundle_id")}
    if receipt is None:
        derived = "unverified"
    else:
        b = receipt["binding"]; bound = False
        if b["kind"] == "origin":
            bound = target["platform"] in ("web", "electron") and b["origin"] == target["identity"].get("origin")
        else:
            keys = binding_keys.get(target["platform"])
            bound = keys is not None and b["identity"] == {k: target["identity"][k] for k in keys if k in target["identity"]}
        if not bound or (b["kind"] == "installed" and b["installed_sha256"] not in (None, b["product_sha256"])) \
                or receipt["source"]["revision"] != parsed["repository"]["head_end"] \
                or receipt["source"]["fingerprint"] not in (None, end["fingerprint"]):
            derived = "contradicted"
        elif b["kind"] == "installed" and b["installed_sha256"] is None:
            derived = "unverified"
        elif receipt["source"]["fingerprint"] is None and end["entries"]:
            derived = "verified-commit-only"
        else:
            derived = "verified"
    if derived != parsed["build"]["freshness"]:
        problems.append(f"{name}: freshness {parsed['build']['freshness']} != derived {derived}")
    if derived == "verified-commit-only":
        unbound = sorted({e["path"] for e in end["entries"]})
    elif derived == "verified":
        unbound = sorted({e["path"] for e in end["entries"] if "omitted" in e})
    else:
        unbound = []
    if parsed["build"]["unbound_paths"] != unbound:
        problems.append(f"{name}: unbound_paths != derived {unbound}")
    if (parsed["scope"]["start"] is not None and parsed["scope"]["start"]["head"] == end["head"]
            and parsed["scope"]["committed_changes"]):
        problems.append(f"{name}: committed_changes with equal heads")
    covered = {c["path"] for c in parsed["coverage"]["paths"]}
    scoped = {c["path"] for c in parsed["scope"]["changed_paths"]} | set(parsed["task"]["reported_paths"])
    if covered != scoped:
        problems.append(f"{name}: coverage set != scoped set")
# Every documented rule with a fixture-expressible outcome has at least one negative.
fixture_codes = {c for case in cases.values() if case["expect"] != "valid" for c in case["expect"]["invalid"]}
uncovered = documented - fixture_codes - {"WT-OUTPUT-CONTAINMENT", "WT-RUN-ID", "WT-CHAPTER-ID", "WT-CHAPTER-ASSET",
                                          "WT-ASSET-ID", "WT-SCOPE-ENTRY", "WT-COVERAGE-CHAPTER"}
if uncovered:
    problems.append(f"documented rules without a negative fixture: {sorted(uncovered)}")
print("\n".join(problems))
PY
)
check "fixture index, controls, codes, hashes, fingerprints and freshness are consistent" "" "$out"

# --- 6. documentation links resolve ---------------------------------------------
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

# --- 7. portability: no machine paths in shipped files --------------------------
# The suite excludes itself: this pattern would otherwise match its own source.
home_hits=$(grep -rIl -E '/Users/|/home/[a-z]' --exclude="$(basename "$0")" "$PLUGIN" 2>/dev/null | head -3)
check "shipped files contain no machine-specific home path" "" "$home_hits"

# =============================================================================
# Stage 2: validator, renderer and scope helper (sections 8-14)
#
# Every helper call goes through the dispatcher (walkthrough.sh). Every negative
# assertion has a positive control run in the same suite. Throwaway git
# repositories live under one mktemp directory, are isolated from user and
# system git configuration, and are removed on exit. Nothing is written under
# this repository.
# =============================================================================
WTSH="$HERE/walkthrough.sh"

command -v git >/dev/null 2>&1 || {
	printf 'session-walkthrough: git is required to run this suite\n' >&2
	exit 1
}
unset SESSION_WALKTHROUGH_OUTPUT_ROOT SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS

TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/walkthrough-test.XXXXXX") || exit 1
TMPROOT=$(cd "$TMPROOT" && pwd -P)
HOLDER_PID=""
cleanup() {
	if [ -n "$HOLDER_PID" ]; then kill "$HOLDER_PID" 2>/dev/null; fi
	case "$TMPROOT" in
	*/walkthrough-test.*) rm -rf "$TMPROOT" ;;
	esac
}
trap cleanup EXIT

# apply_results LABEL: read "PASS<TAB>text", "FAIL<TAB>text<TAB>detail" and a
# final "DONE" line from a checker; a checker that dies before DONE is a failure.
apply_results() {
	local label="$1" status text detail done_seen=0
	while IFS=$'\t' read -r status text detail; do
		case "$status" in
		PASS) pass ;;
		FAIL) fail "$text" "$detail" ;;
		DONE) done_seen=1 ;;
		*) [ -n "$status" ] && fail "$label: unexpected checker output: $status $text" ;;
		esac
	done
	[ "$done_seen" -eq 1 ] || fail "$label: the checker did not run to completion"
}

RUN_OUT=""
RUN_ERR=""
RUN_RC=0
# run_wt [ENV=VALUE ...] -- ARG...   Run the dispatcher; results land in RUN_OUT, RUN_ERR, RUN_RC.
run_wt() {
	local -a vars=()
	while [ $# -gt 0 ] && [ "$1" != "--" ]; do
		vars+=("$1")
		shift
	done
	[ "${1:-}" = "--" ] && shift
	RUN_OUT=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 ${vars[@]+"${vars[@]}"} bash "$WTSH" "$@" 2>"$TMPROOT/stderr")
	RUN_RC=$?
	RUN_ERR=$(cat "$TMPROOT/stderr")
}

# g REPO ARG...   git in a throwaway repository, isolated from user and system configuration.
g() {
	local repo="$1"
	shift
	env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git -C "$repo" -c commit.gpgsign=false "$@"
}

# make_repo DIR   a committed repository with an ignored .tmp/ and a few tracked files.
make_repo() {
	local repo="$1"
	mkdir -p "$repo/app/settings" "$repo/lib" "$repo/docs" || return 1
	g "$repo" init -q 2>/dev/null || return 1
	g "$repo" config user.name "Walkthrough Test"
	g "$repo" config user.email "walkthrough-test@example.invalid"
	g "$repo" config commit.gpgsign false
	printf '.tmp/\nignored.log\n' >"$repo/.gitignore"
	printf 'one\n' >"$repo/app/settings/Panel.tsx"
	printf 'one\n' >"$repo/app/settings/theme.css"
	printf 'one\n' >"$repo/lib/format.ts"
	printf 'one\n' >"$repo/docs/readme.md"
	g "$repo" add -A && g "$repo" commit -q -m "initial" || return 1
	mkdir -p "$repo/.tmp"
}

# wtlib.py: helpers the Python checkers share. Checkers run from $TMPROOT, so they import it directly.
cat >"$TMPROOT/wtlib.py" <<'PY'
import json
import os
import shutil
import subprocess

ENV = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def say(ok, text, detail=""):
    if ok:
        print("PASS\t" + text)
    else:
        print("FAIL\t%s\t%s" % (text, str(detail).replace("\t", " ").replace("\n", " | ")[:500]))


def run(wtsh, args, extra_env=None):
    env = dict(ENV)
    env.update(extra_env or {})
    return subprocess.run(["bash", wtsh] + list(args), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, env=env)


def codes_of(text):
    return set(line.split(" ", 1)[0] for line in text.splitlines() if line.startswith("WT-"))


def head_at(manifest_path, which):
    """The synthetic head a fixture records at scope.start or scope.end."""
    return json.load(open(manifest_path, encoding="utf-8"))["scope"][which]["head"]


def build_run(repo, fixrun, base, run_id, shas=None, mutate=None):
    """<repo>/.tmp/walkthroughs/<run_id>/ holding the fixture assets and a manifest.json made from base.

    shas maps a head found in the fixture text to the head to write at every site (scope,
    repository and receipt); mutate edits the parsed manifest last. The directory name equals run.id.
    """
    text = open(base, encoding="utf-8").read()
    for old, new in (shas or {}).items():
        text = text.replace(old, new)
    manifest = json.loads(text)
    manifest["run"]["id"] = run_id
    if mutate is not None:
        mutate(manifest)
    parent = os.path.join(repo, ".tmp", "walkthroughs")
    target = os.path.join(parent, run_id)
    os.makedirs(parent, exist_ok=True)
    shutil.copytree(os.path.join(fixrun, "assets"), os.path.join(target, "assets"))
    with open(os.path.join(target, "manifest.json"), "w", encoding="utf-8") as stream:
        json.dump(manifest, stream, indent=2)
    return target
PY

# --- 8. validator against every fixture -----------------------------------------
cat >"$TMPROOT/check-matrix.py" <<'PY'
import json, os, subprocess, sys

here, wtsh = sys.argv[1], sys.argv[2]
fix = os.path.join(here, "fixtures")
index = json.load(open(os.path.join(fix, "manifests", "index.json")))
run_dir = os.path.normpath(os.path.join(fix, "manifests", index["run_dir"]))
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def run(args):
    return subprocess.run(["bash", wtsh] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, env=env)


def say(ok, text, detail=""):
    if ok:
        print("PASS\t" + text)
    else:
        print("FAIL\t%s\t%s" % (text, detail.replace("\t", " ").replace("\n", " | ")[:400]))


def codes_of(text):
    return [line.split(" ", 1)[0] for line in text.splitlines() if line.startswith("WT-")]


clean = {}
for name, case in sorted(index["cases"].items()):
    path = os.path.join(fix, "manifests", name)
    plain = run(["validate", "--manifest", path, "--run-dir", run_dir])
    as_json = run(["validate", "--manifest", path, "--run-dir", run_dir, "--json"])
    try:
        doc = json.loads(as_json.stdout)
    except ValueError:
        say(False, "validate %s: --json output parses" % name, as_json.stdout[:200] + as_json.stderr[:200])
        continue
    text_codes = set(codes_of(plain.stdout))
    json_codes = set(item["code"] for item in doc.get("failures", []))
    last = plain.stdout.strip().splitlines()[-1] if plain.stdout.strip() else ""
    well_formed = all(len(line.split(" ", 2)) == 3 for line in plain.stdout.splitlines() if line.startswith("WT-"))
    if case["expect"] == "valid":
        clean[name] = plain.returncode == 0 and not text_codes
        say(plain.returncode == 0 and not text_codes and last.startswith("valid:"),
            "validate %s: valid control exits 0 with no failure lines" % name, plain.stdout + plain.stderr)
        say(as_json.returncode == 0 and doc.get("valid") is True and doc.get("failures") == [],
            "validate %s --json: valid control agrees" % name, as_json.stdout[:300])
    else:
        want = set(case["expect"]["invalid"])
        say(plain.returncode == 1 and want <= text_codes and last.startswith("invalid:") and well_formed,
            "validate %s: exits 1 and reports %s" % (name, sorted(want)),
            "rc=%d codes=%s" % (plain.returncode, sorted(text_codes)))
        say(as_json.returncode == 1 and doc.get("valid") is False and json_codes == text_codes and want <= json_codes,
            "validate %s --json: agrees with the text output" % name,
            "json=%s text=%s" % (sorted(json_codes), sorted(text_codes)))
for name, case in sorted(index["cases"].items()):
    if case["expect"] != "valid":
        control = case["control"]
        say(clean.get(control) is True, "validate %s: its control %s validated clean in this run" % (name, control))
print("DONE")
PY
apply_results "fixture matrix" < <(python3 -B "$TMPROOT/check-matrix.py" "$HERE" "$WTSH")

# --- 9. renderer ----------------------------------------------------------------
cat >"$TMPROOT/check-render.py" <<'PY'
import hashlib, json, os, re, shutil, subprocess, sys
from html.parser import HTMLParser
from wtlib import build_run, head_at

here, wtsh, tmproot, repo, head = sys.argv[1:6]
fix = os.path.join(here, "fixtures")
index = json.load(open(os.path.join(fix, "manifests", "index.json")))
src_run = os.path.normpath(os.path.join(fix, "manifests", index["run_dir"]))
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
VOID = frozenset("area base br col embed hr img input link meta param source track wbr".split())
LINE_SEPARATOR = chr(0x2028)
RUNS = os.path.join(repo, ".tmp", "walkthroughs")


def contained_copy(run_id):
    """A fresh copy of the fixture run directory in the throwaway repository's ignored output root.

    render writes only inside a git-ignored run directory, whether or not --manifest is given.
    """
    os.makedirs(RUNS, exist_ok=True)
    target = os.path.join(RUNS, run_id)
    shutil.copytree(src_run, target)
    return target


def run(args):
    return subprocess.run(["bash", wtsh] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, env=env)


def say(ok, text, detail=""):
    if ok:
        print("PASS\t" + text)
    else:
        print("FAIL\t%s\t%s" % (text, str(detail).replace("\t", " ").replace("\n", " | ")[:400]))


class Page(HTMLParser):
    def __init__(self):
        HTMLParser.__init__(self, convert_charrefs=True)
        self.stack = []
        self.problems = []
        self.elements = []
        self.chunks = []
        self.json_chunks = []
        self.in_json = False
        self.counter = 0

    def _open(self, tag, attrs, void):
        self.counter += 1
        attrs = dict(attrs)
        self.elements.append({"tag": tag, "attrs": attrs, "uid": self.counter,
                              "ancestors": [item["uid"] for item in self.stack]})
        if tag == "script" and attrs.get("id") == "walkthrough-manifest":
            self.in_json = True
        if not void:
            self.stack.append({"tag": tag, "attrs": attrs, "uid": self.counter})

    def handle_starttag(self, tag, attrs):
        self._open(tag, attrs, tag in VOID)

    def handle_startendtag(self, tag, attrs):
        self._open(tag, attrs, True)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.stack and self.stack[-1]["tag"] == tag:
            self.stack.pop()
        else:
            self.problems.append("unbalanced </%s>" % tag)
        if tag == "script":
            self.in_json = False

    def handle_data(self, data):
        if self.in_json:
            self.json_chunks.append(data)
        else:
            self.chunks.append({"text": data, "uids": [item["uid"] for item in self.stack],
                                "tags": [item["tag"] for item in self.stack]})

    def visible_chunks(self):
        return [c for c in self.chunks if "script" not in c["tags"] and "style" not in c["tags"]]

    def text_in(self, uid):
        return "".join(c["text"] for c in self.visible_chunks() if uid in c["uids"])

    def find(self, tag=None, **attrs):
        found = []
        for el in self.elements:
            if tag is not None and el["tag"] != tag:
                continue
            if all((key.rstrip("_").replace("_", "-") in el["attrs"]) if value is True else
                   (el["attrs"].get(key.rstrip("_").replace("_", "-")) == value) for key, value in attrs.items()):
                found.append(el)
        return found

    def with_class(self, name):
        return [el for el in self.elements if name in (el["attrs"].get("class") or "").split()]


def render_fixture(name, work):
    path = os.path.join(fix, "manifests", name)
    out = os.path.join(work, "report.html")
    proc = run(["render", "--manifest", path, "--run-dir", work, "--output", out])
    return proc, out


def check_fixture(name):
    label = "render %s" % name[:-5]
    manifest = json.load(open(os.path.join(fix, "manifests", name)))
    work = contained_copy(manifest["run"]["id"])
    proc, out = render_fixture(name, work)
    say(proc.returncode == 0 and os.path.isfile(out), label + ": exits 0 and writes the page", proc.stderr + proc.stdout)
    if not os.path.isfile(out):
        return
    expected_hash = hashlib.sha256(open(os.path.join(fix, "manifests", name), "rb").read()).hexdigest()
    say(("manifest-sha256: " + expected_hash) in proc.stdout, label + ": reports the manifest SHA-256", proc.stdout)
    raw = open(out, "rb").read()
    try:
        data = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        say(False, label + ": the page is plain ASCII", exc)
        return
    say(True, label + ": the page is plain ASCII")
    page = Page()
    page.feed(data)
    page.close()
    say(not page.problems and not page.stack, label + ": html.parser finds balanced markup", page.problems[:3])
    block = "".join(page.json_chunks)
    try:
        copy = json.loads(block)
    except ValueError as exc:
        copy = None
        say(False, label + ": the inline manifest block parses", exc)
    if copy is not None:
        say(copy == manifest, label + ": the inline manifest block equals the manifest")
    say(not any(ch in block for ch in "<>&") and "</script" not in block.lower(),
        label + ": the inline manifest block has no raw <, > or & and cannot close the script element")
    say(re.search(rb"https?://", raw, re.I) is None, label + ": no http:// or https:// anywhere in the page")
    say(b"<track" not in raw.lower(), label + ": no <track> element")
    bad = []
    for el in page.elements:
        for key, value in el["attrs"].items():
            text = (value or "").strip().lower()
            if key.startswith("on"):
                bad.append("event attribute %s on <%s>" % (key, el["tag"]))
            if "javascript:" in text or text.startswith("data:") or text.startswith("//"):
                bad.append("%s=%r on <%s>" % (key, value, el["tag"]))
        if el["tag"] in ("link", "iframe", "object", "embed", "form", "base") or (
                el["tag"] == "script" and "src" in el["attrs"]):
            bad.append("external-capable element <%s>" % el["tag"])
        if el["tag"] in ("img", "video", "source", "audio"):
            if not re.fullmatch(r"assets/[A-Za-z0-9][A-Za-z0-9._-]*", el["attrs"].get("src") or ""):
                bad.append("<%s> src %r is not a relative assets/ path" % (el["tag"], el["attrs"].get("src")))
        if el["tag"] == "a":
            href = el["attrs"].get("href") or ""
            if not (href.startswith("#") or re.fullmatch(r"assets/[A-Za-z0-9][A-Za-z0-9._-]*", href)):
                bad.append("<a> href %r" % href)
    style = "".join(c["text"] for c in page.chunks if "style" in c["tags"])
    if "url(" in style or "@import" in style:
        bad.append("CSS reference")
    say(not bad, label + ": no event handler, javascript:, data:, external or non-relative reference", bad[:3])
    paths = set(asset["path"] for asset in manifest["assets"])
    sources = set(el["attrs"]["src"] for el in page.elements if el["tag"] in ("img", "video"))
    say(sources <= paths, label + ": every media src is a manifest asset path", sources - paths)
    hostile = [s for s in walk_strings(manifest) if "<" in s]
    leaked = [s for s in hostile if s in data]
    all_text = " ".join(c["text"] for c in page.visible_chunks())
    missing = [s for s in hostile if s.replace(LINE_SEPARATOR, "[U+2028]") not in all_text]
    say(not leaked and not missing, label + ": every manifest string containing < appears only as escaped text",
        "leaked=%s missing=%s" % (leaked[:2], missing[:2]))
    if name == "valid-hostile-text.json":
        say(len(hostile) >= 3 and "<img src=x onerror" not in data and "<script>alert" not in data
            and "&lt;img src=x onerror" in data and "&lt;track" in data and "<track" not in data,
            label + ": control - the hostile payloads are present and only escaped", len(hostile))
        say("javascript:alert(4)" in all_text and not any("javascript:" in (v or "") for el in page.elements
                                                          for v in el["attrs"].values()),
            label + ": control - javascript: appears as text, never in an attribute")
        say("[U+2028]" in all_text, label + ": control - a line separator is shown as a visible marker")
    for chapter in manifest["chapters"]:
        articles = page.find("article", data_chapter=chapter["id"])
        if len(articles) != 1:
            say(False, label + ": chapter %s has exactly one article" % chapter["id"], len(articles))
            continue
        article = articles[0]
        inside = [el for el in page.elements if article["uid"] in el["ancestors"]]
        markers = [el for el in inside if "before-unavailable" in (el["attrs"].get("class") or "").split()]
        if chapter["before"]["asset"] is None:
            text = page.text_in(markers[0]["uid"]) if markers else ""
            say(len(markers) == 1 and text.startswith("Before unavailable") and chapter["before"]["unavailable_reason"] in text,
                label + ": chapter %s shows a before-unavailable marker with its reason" % chapter["id"], text)
        else:
            say(not markers and any(el["tag"] in ("img", "video") and el["attrs"].get("src") == next(
                a["path"] for a in manifest["assets"] if a["id"] == chapter["before"]["asset"]) for el in inside),
                label + ": control - chapter %s with a baseline shows it and no marker" % chapter["id"])
        if chapter["status"] != "demonstrated":
            say(article["attrs"].get("data-status") == chapter["status"] and chapter["reason"] in page.text_in(article["uid"]),
                label + ": chapter %s shows its %s status and reason" % (chapter["id"], chapter["status"]))
    failed = [c for c in manifest["chapters"] if c["status"] != "demonstrated"]
    banners = page.find("li", data_notice="failed-chapters")
    say(bool(banners) == bool(failed), label + ": the failed-chapters notice appears exactly when a chapter failed or was skipped")
    say(bool(page.find("li", data_notice="run-status")) == (manifest["run"]["status"] != "complete"),
        label + ": the run-status notice appears exactly when the run is not complete")
    kinds = page.find(data_recording_kind=True)
    only_stills = all(a["recording_kind"] == "stills" for a in manifest["assets"])
    bad_kind = []
    for el in kinds:
        kind, text = el["attrs"]["data-recording-kind"], page.text_in(el["uid"]).lower()
        if kind == "stills" and ("continuous" in text or "stills" not in text):
            bad_kind.append((kind, text[:60]))
        if kind == "continuous" and "continuous recording" not in text:
            bad_kind.append((kind, text[:60]))
        if kind == "frame-sampled" and "frame-sampled" not in text:
            bad_kind.append((kind, text[:60]))
    say(bool(kinds) == bool(manifest["assets"]) and not bad_kind,
        label + ": every asset carries a truthful recording-kind label", bad_kind[:2])
    if only_stills:
        say("continuous" not in all_text.lower(), label + ": a stills-only report never says continuous")
    elif any(a["recording_kind"] == "continuous" for a in manifest["assets"]):
        say("continuous recording" in all_text.lower(), label + ": control - a continuous clip is labelled continuous")
    for asset in manifest["assets"]:
        if not asset["media_type"].startswith("video/"):
            continue
        videos = [el for el in page.find("video", data_asset=asset["id"])]
        lists = page.find("ol", data_asset=asset["id"])
        if not videos:
            continue
        el = videos[0]
        say(len(videos) == 1 and "controls" in el["attrs"] and el["attrs"].get("preload") == "metadata"
            and el["attrs"].get("src") == asset["path"], label + ": clip %s is a controlled, metadata-preloaded video" % asset["id"])
        items = [x for x in page.elements if lists and lists[0]["uid"] in x["ancestors"] and x["tag"] == "li"]
        texts = [page.text_in(x["uid"]) for x in items]
        want = [c["text"].replace(LINE_SEPARATOR, "[U+2028]") for c in asset["captions"]]
        say(len(items) == len(asset["captions"]) and all(t.endswith(w) for t, w in zip(texts, want)),
            label + ": every cue of clip %s is listed as static text" % asset["id"], texts[:2])
        say(any(x["tag"] == "div" and "overlay" in (x["attrs"].get("class") or "") for x in page.elements)
            and any(x["tag"] == "script" and not x["attrs"] for x in page.elements),
            label + ": clip %s has a caption overlay and an inline script" % asset["id"])
    freshness = page.find(data_freshness=True)
    say(len(freshness) == 1 and freshness[0]["attrs"]["data-freshness"] == manifest["build"]["freshness"]
        and page.text_in(freshness[0]["uid"]).strip() == manifest["build"]["freshness"],
        label + ": build.freshness is shown verbatim as a label")
    unbound = page.find("ul", class_="unbound")
    listed = [page.text_in(x["uid"]) for u in unbound for x in page.elements
              if u["uid"] in x["ancestors"] and x["tag"] == "code"]
    say(listed == manifest["build"]["unbound_paths"] and bool(unbound) == bool(manifest["build"]["unbound_paths"]),
        label + ": build.unbound_paths are listed under the label, and only when present", listed)
    if manifest["build"]["freshness"] == "verified-commit-only":
        banner = page.find("li", data_notice="build-freshness")[0]
        text = page.text_in(banner["uid"])
        say("commit is bound" in text and "not" in text, label + ": verified-commit-only says the commit is bound and the paths are not")
    committed = page.find("li", data_notice="committed-changes")
    say(bool(committed) == bool(manifest["scope"]["committed_changes"])
        and all(c["path"] in page.text_in(committed[0]["uid"]) for c in manifest["scope"]["committed_changes"]),
        label + ": committed changes are listed exactly when present")
    notices = page.find("li", data_notice="discrepancies")
    say(bool(notices) == bool(manifest["scope"]["discrepancies"]) and all(
        d["kind"] in page.text_in(notices[0]["uid"]) for d in manifest["scope"]["discrepancies"]),
        label + ": discrepancies are shown")
    limits = page.find("li", data_notice="limitations")
    wanted = manifest["scope"]["limitations"] + manifest["coverage"]["limitations"]
    say(bool(limits) == bool(wanted) and all(
        x.replace(LINE_SEPARATOR, "[U+2028]") in page.text_in(limits[0]["uid"]) for x in wanted),
        label + ": limitations are shown")
    again = os.path.join(work, "again.html")
    proc2 = run(["render", "--manifest", os.path.join(fix, "manifests", name), "--run-dir", work, "--output", again])
    say(proc2.returncode == 0 and open(again, "rb").read() == raw, label + ": rendering twice gives identical bytes")


def walk_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, dict):
        for key, value in node.items():
            for item in walk_strings(key):
                yield item
            for item in walk_strings(value):
                yield item
    elif isinstance(node, list):
        for value in node:
            for item in walk_strings(value):
                yield item


for name, case in sorted(index["cases"].items()):
    if case["expect"] == "valid":
        check_fixture(name)

# Refusals, each beside a control that succeeds.
negative = "asset-sha256-mismatch.json"
work = contained_copy("wt-render-refused-0001")
proc = run(["render", "--manifest", os.path.join(fix, "manifests", negative), "--run-dir", work])
say(proc.returncode == 1 and "WT-ASSET-HASH" in proc.stdout and not os.path.exists(os.path.join(work, "index.html")),
    "render refuses an invalid manifest (exit 1, failures printed, no page written)", proc.stdout + proc.stderr)
proc = run(["render", "--manifest", os.path.join(fix, "manifests", "valid-synthetic.json"), "--run-dir", work])
say(proc.returncode == 0 and os.path.isfile(os.path.join(work, "index.html")),
    "render control: the valid manifest in the same run directory writes the default index.html", proc.stderr)
outside = os.path.join(tmproot, "outside-render.html")
proc = run(["render", "--manifest", os.path.join(fix, "manifests", "valid-synthetic.json"), "--run-dir", work, "--output", outside])
say(proc.returncode == 2 and not os.path.exists(outside), "render refuses --output outside the run directory", proc.stderr)
os.mkdir(os.path.join(work, "nested"))
proc = run(["render", "--manifest", os.path.join(fix, "manifests", "valid-synthetic.json"), "--run-dir", work,
            "--output", os.path.join(work, "nested", "index.html")])
say(proc.returncode == 2, "render refuses --output in a subdirectory (relative assets/ links would break)", proc.stderr)
victim = os.path.join(tmproot, "victim.txt")
open(victim, "w").write("untouched")
link_dir = contained_copy("wt-render-link-0001")
os.symlink(victim, os.path.join(link_dir, "index.html"))
proc = run(["render", "--manifest", os.path.join(fix, "manifests", "valid-synthetic.json"), "--run-dir", link_dir])
say(proc.returncode == 2 and open(victim).read() == "untouched" and os.path.islink(os.path.join(link_dir, "index.html")),
    "render never follows a symlink at the destination (target untouched, exit 2)", proc.stderr)
os.unlink(os.path.join(link_dir, "index.html"))
proc = run(["render", "--manifest", os.path.join(fix, "manifests", "valid-synthetic.json"), "--run-dir", link_dir])
say(proc.returncode == 0 and not os.path.islink(os.path.join(link_dir, "index.html")),
    "render control: without the symlink the page is written as a regular file", proc.stderr)
proc = run(["render", "--manifest", os.path.join(fix, "manifests", "valid-synthetic.json"), "--run-dir", os.path.join(tmproot, "no-such-dir")])
say(proc.returncode == 2, "render exits 2 for a missing run directory", proc.stderr)

# Write containment never depends on --manifest. Each refusal names its reason, leaves the run
# directory exactly as it was (no page, no lock), and sits beside a control that renders.
valid = os.path.join(fix, "manifests", "valid-synthetic.json")
valid_head = head_at(valid, "end")


def listing(path):
    return sorted(os.listdir(path))


def refused(label, run_dir, reason, use_manifest=True):
    before = listing(run_dir)
    args = ["render", "--run-dir", run_dir] + (["--manifest", valid] if use_manifest else [])
    proc = run(args)
    say(proc.returncode == 2 and reason in proc.stderr and listing(run_dir) == before,
        label, "rc=%d before=%s after=%s %s" % (proc.returncode, before, listing(run_dir), proc.stderr.strip()))


control = contained_copy("wt-render-control-0001")
proc = run(["render", "--manifest", valid, "--run-dir", control])
say(proc.returncode == 0 and os.path.isfile(os.path.join(control, "index.html")) and not os.path.exists(os.path.join(control, ".lock")),
    "control: the same manifest rendered in a contained run directory exits 0, writes index.html and leaves no lock", proc.stderr)
outside = os.path.join(tmproot, "outside-any-repo", "wt-outside-render-0001")
os.makedirs(os.path.dirname(outside))
shutil.copytree(src_run, outside)
refused("render --manifest refuses a run directory outside any git repository (exit 2, nothing written)", outside, "git work tree")
shutil.copy(valid, os.path.join(outside, "manifest.json"))
refused("render without --manifest refuses the same directory (exit 2, nothing written)", outside, "git work tree", use_manifest=False)
visible = os.path.join(repo, "visible", "wt-visible-render-0001")
os.makedirs(os.path.dirname(visible))
shutil.copytree(src_run, visible)
refused("render --manifest refuses a run directory that git does not ignore (exit 2, nothing written)", visible, "ignore")
alias_target = os.path.join(repo, ".tmp", "alias-target")
os.makedirs(alias_target)
real = os.path.join(alias_target, "wt-alias-render-0001")
shutil.copytree(src_run, real)
os.symlink(alias_target, os.path.join(repo, ".tmp", "alias-link"))
refused("render --manifest refuses an ancestor symlink to a real ignored directory (exit 2, nothing written through it)",
        os.path.join(repo, ".tmp", "alias-link", "wt-alias-render-0001"), "symlink")
proc = run(["render", "--manifest", valid, "--run-dir", real])
say(proc.returncode == 0 and os.path.isfile(os.path.join(real, "index.html")),
    "control: the real directory behind the alias renders", proc.stderr)
away = os.path.join(tmproot, "alias-away")
shutil.copytree(src_run, os.path.join(away, "wt-away-render-0001"))
os.symlink(away, os.path.join(repo, ".tmp", "alias-away-link"))
refused("render --manifest refuses an ancestor symlink to a directory outside any repository (exit 2, nothing written)",
        os.path.join(repo, ".tmp", "alias-away-link", "wt-away-render-0001"), "git work tree")
os.symlink(away, os.path.join(tmproot, "alias-outside-link"))
refused("render --manifest refuses an ancestor symlink placed outside the repository too (exit 2, nothing written)",
        os.path.join(tmproot, "alias-outside-link", "wt-away-render-0001"), "git work tree")
final_real = contained_copy("wt-final-real-0001")
os.symlink(final_real, os.path.join(RUNS, "wt-final-link-0001"))
refused("render --manifest refuses a symlink as the run directory itself (exit 2, nothing written)",
        os.path.join(RUNS, "wt-final-link-0001"), "symlink")
rundir_mode = build_run(repo, src_run, valid, "wt-render-rundir-0001", {valid_head: head})
proc = run(["render", "--run-dir", rundir_mode])
say(proc.returncode == 0 and os.path.isfile(os.path.join(rundir_mode, "index.html")),
    "control: render without --manifest writes the page in a contained run directory", proc.stdout + proc.stderr)
print("DONE")
PY
RENDER_REPO="$TMPROOT/repo-render"
make_repo "$RENDER_REPO" || fail "the render throwaway repository could not be created"
apply_results "render" < <(python3 -B "$TMPROOT/check-render.py" "$HERE" "$WTSH" "$TMPROOT" "$RENDER_REPO" "$(g "$RENDER_REPO" rev-parse HEAD)")

# --- 10. scope helper in a throwaway git repository -----------------------------
REPO="$TMPROOT/repo"
make_repo "$REPO" || fail "the throwaway repository could not be created"
printf 'two\n' >"$REPO/app/settings/theme.css"
printf 'wip\n' >"$REPO/app/settings/wip.css"
printf 'x\n' >"$REPO/notignored.log"
printf 'x\n' >"$REPO/ignored.log"
RUN_MAIN="$REPO/.tmp/walkthroughs/wt-scope-main-0001"
run_wt SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES=16 -- scope start --repo "$REPO" --run wt-scope-main-0001 --where app/settings
check "scope start exits 0" "0" "$RUN_RC"
check "scope start prints the resolved run directory first" "run-dir: $RUN_MAIN" "$(printf '%s\n' "$RUN_OUT" | head -1)"
printf 'one\ntwo\n' >"$REPO/app/settings/Panel.tsx"
printf 'two\n' >"$REPO/lib/format.ts"
printf 'one\n' >"$REPO/app/settings/theme.css"
printf 'SECRET-MARKER-1\n' >"$REPO/app/settings/new.css"
printf '%0100d' 0 >"$REPO/big.bin"
printf 'changed\n' >"$REPO/ignored.log"
rm "$REPO/docs/readme.md"
run_wt SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES=16 -- scope end --repo "$REPO" --run wt-scope-main-0001 \
	--where app/settings --reported app/settings/Panel.tsx lib/format.ts docs/missing.md \
	--shared-tree --task task-1 --workflow wf-1 --executor exec-1 --project-id sample-project
check "scope end exits 0" "0" "$RUN_RC"
check "scope end leaves no lock behind" "no" "$([ -e "$RUN_MAIN/.lock" ] && echo yes || echo no)"
HEAD_NOW=$(g "$REPO" rev-parse HEAD)
BRANCH_NOW=$(g "$REPO" symbolic-ref --short -q HEAD)

cat >"$TMPROOT/check-scope.py" <<'PY'
import copy, hashlib, json, os, re, shutil, subprocess, sys

scenario = sys.argv[1]
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def say(ok, text, detail=""):
    if ok:
        print("PASS\t" + text)
    else:
        print("FAIL\t%s\t%s" % (text, str(detail).replace("\t", " ").replace("\n", " | ")[:500]))


def load(path):
    return json.load(open(path))


def fingerprint(entries):
    canon = json.dumps(sorted(entries, key=lambda e: e["path"]), sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return hashlib.sha256(canon.encode()).hexdigest()


def paste(summary, base_path, work):
    """A complete manifest from valid-synthetic.json with the helper's blocks pasted in."""
    m = load(base_path)
    m["repository"], m["task"], m["scope"] = summary["repository"], summary["task"], summary["scope"]
    m["build"] = {"freshness": "unverified", "receipt": None, "unbound_paths": [],
                  "reason": "Test manifest without a build receipt"}
    changed = dict((c["path"], c["change"]) for c in summary["scope"]["changed_paths"])
    scoped = sorted(set(changed) | set(summary["task"]["reported_paths"]))
    demonstrated = scoped[0]
    m["chapters"][0]["source_paths"] = [demonstrated]
    paths = []
    for path in scoped:
        if path == demonstrated:
            paths.append({"path": path, "status": "demonstrated", "chapters": [m["chapters"][0]["id"]], "reason": None})
        elif path not in changed:
            paths.append({"path": path, "status": "omitted: out-of-scope", "chapters": [], "reason": "Reported but not observed"})
        elif changed[path] == "unknown":
            paths.append({"path": path, "status": "omitted: unobserved", "chapters": [], "reason": "Change is unknown"})
        else:
            paths.append({"path": path, "status": "omitted: non-visual", "chapters": [], "reason": "No rendered surface"})
    m["coverage"]["paths"] = paths
    target = os.path.join(work, "pasted.json")
    json.dump(m, open(target, "w"), indent=2)
    return m, target


def validate(wtsh, manifest, run_dir, extra=()):
    proc = subprocess.run(["bash", wtsh, "validate", "--manifest", manifest, "--run-dir", run_dir] + list(extra),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True, env=env)
    codes = set(line.split(" ", 1)[0] for line in proc.stdout.splitlines() if line.startswith("WT-"))
    return proc, codes


if scenario == "main":
    run_dir, repo, head, branch, wtsh, fixrun, base, work = sys.argv[2:10]
    start, end, summary = (load(os.path.join(run_dir, n)) for n in ("scope-start.json", "scope-end.json", "scope-summary.json"))
    st = dict((e["path"], e) for e in start["entries"])
    en = dict((e["path"], e) for e in end["entries"])
    say(set(st) == {"app/settings/theme.css", "app/settings/wip.css", "notignored.log"},
        "scope start lists exactly the dirty tracked and non-ignored untracked files", sorted(st))
    say("ignored.log" not in st and "ignored.log" not in en and os.path.exists(os.path.join(repo, "ignored.log")),
        "an ignored file never appears in a snapshot (control: it exists on disk)")
    say("notignored.log" in st and "notignored.log" in en, "control: a similar non-ignored file does appear")
    say((st["app/settings/theme.css"]["state"], st["app/settings/wip.css"]["state"]) == ("modified", "untracked"),
        "snapshot states map to modified and untracked")
    say(start["max_bytes"] == 16 and end["max_bytes"] == 16, "max_bytes records the tunable")
    say(start["fingerprint"] == fingerprint(start["entries"]) and end["fingerprint"] == fingerprint(end["entries"]),
        "fingerprints recompute from the entries")
    say([e["path"] for e in end["entries"]] == sorted(en), "entries are sorted by path")
    say(en["big.bin"]["omitted"] == "size" and en["big.bin"]["sha256"] is None and en["big.bin"]["bytes"] is None,
        "a file over the size limit is omitted: size with null hash and size")
    small = en["app/settings/Panel.tsx"]
    data = open(os.path.join(repo, "app/settings/Panel.tsx"), "rb").read()
    say(small["sha256"] == hashlib.sha256(data).hexdigest() and small["bytes"] == len(data) and "omitted" not in small,
        "control: a small file is hashed with its true digest and size")
    say(en["docs/readme.md"]["state"] == "deleted" and en["docs/readme.md"]["omitted"] == "deleted"
        and en["docs/readme.md"]["sha256"] is None, "a deleted file is state deleted, omitted: deleted")
    say(en["app/settings/new.css"]["state"] == "untracked" and en["lib/format.ts"]["state"] == "modified",
        "end states map to untracked and modified")
    blob = "".join(open(os.path.join(run_dir, n)).read() for n in ("scope-start.json", "scope-end.json", "scope-summary.json"))
    say("SECRET-MARKER-1" not in blob and "SECRET-MARKER-1" in open(os.path.join(repo, "app/settings/new.css")).read(),
        "file contents are never stored (control: the marker is in the file)")
    rows = dict((c["path"], c) for c in summary["scope"]["changed_paths"])
    expect = {
        "app/settings/Panel.tsx": ("modified", True, True, "reported-and-observed"),
        "app/settings/new.css": ("added", True, False, "observed-only: attribution uncertain"),
        "app/settings/theme.css": ("unknown", True, False, "observed-only: attribution uncertain"),
        "big.bin": ("added", False, False, "observed-only: attribution uncertain"),
        "docs/readme.md": ("deleted", False, False, "observed-only: attribution uncertain"),
        "lib/format.ts": ("modified", False, True, "reported-and-observed"),
    }
    got = dict((p, (c["change"], c["in_where"], c["reported"], c["attribution"])) for p, c in rows.items())
    say(got == expect, "changed_paths carry the exact change, in_where, reported and attribution values", got)
    say("app/settings/wip.css" not in rows and "notignored.log" not in rows,
        "control: unchanged dirty files are not changed paths")
    say([c["path"] for c in summary["scope"]["changed_paths"]] == sorted(rows), "changed_paths are sorted by path")
    order = lambda x: (x[0], x[1] or "")
    kinds = sorted(((d["kind"], d["path"]) for d in summary["scope"]["discrepancies"]), key=order)
    want = sorted([
        ("outside-where", "big.bin"), ("outside-where", "docs/readme.md"), ("outside-where", "lib/format.ts"),
        ("observed-not-reported", "app/settings/new.css"), ("observed-not-reported", "app/settings/theme.css"),
        ("observed-not-reported", "big.bin"), ("observed-not-reported", "docs/readme.md"),
        ("reported-not-observed", "docs/missing.md"),
        ("fingerprint-omitted", "big.bin"), ("fingerprint-omitted", "docs/readme.md"),
        ("shared-tree: attribution uncertain", None)], key=order)
    say(kinds == want, "the discrepancy kinds and paths are exactly the derived set", kinds)
    say(all(0 < len(d["detail"]) <= 200 and "/" not in d["detail"] for d in summary["scope"]["discrepancies"]),
        "discrepancy details are bounded one-line text that does not embed paths")
    say(summary["repository"] == {"project_id": "sample-project", "head_start": head, "head_end": head,
                                  "branch": branch, "dirty_at_end": True}, "the repository block is exact", summary["repository"])
    say(summary["task"] == {"workflow_id": "wf-1", "task_id": "task-1", "executor": "exec-1", "where": ["app/settings"],
                            "reported_paths": ["app/settings/Panel.tsx", "lib/format.ts", "docs/missing.md"]},
        "the task block is exact", summary["task"])
    say(summary["scope"]["shared_tree"] is True and summary["scope"]["start_unavailable_reason"] is None
        and summary["scope"]["committed_changes"] == [], "shared_tree, start reason and committed changes are exact")
    m, pasted = paste(summary, base, work)
    proc, codes = validate(wtsh, pasted, fixrun)
    say(proc.returncode == 0 and not codes, "control: the pasted scope-summary blocks validate (derivation matches the validator)",
        proc.stdout + proc.stderr)
    broken = copy.deepcopy(m)
    broken["scope"]["changed_paths"][0]["in_where"] = False
    json.dump(broken, open(os.path.join(work, "broken.json"), "w"))
    proc, codes = validate(wtsh, os.path.join(work, "broken.json"), fixrun)
    say(proc.returncode == 1 and "WT-SCOPE-CHANGED" in codes, "a tampered in_where in the pasted blocks is rejected", sorted(codes))
    broken = copy.deepcopy(m)
    broken["scope"]["discrepancies"] = [d for d in broken["scope"]["discrepancies"] if d["kind"] != "reported-not-observed"]
    json.dump(broken, open(os.path.join(work, "broken2.json"), "w"))
    proc, codes = validate(wtsh, os.path.join(work, "broken2.json"), fixrun)
    say(proc.returncode == 1 and "WT-SCOPE-DISCREPANCY" in codes, "a dropped discrepancy in the pasted blocks is rejected", sorted(codes))

elif scenario == "nostart":
    run_dir, wtsh, fixrun, base, work, reason = sys.argv[2:8]
    summary = load(os.path.join(run_dir, "scope-summary.json"))
    block = summary["scope"]
    say(os.path.exists(os.path.join(run_dir, "scope-end.json")) and not os.path.exists(os.path.join(run_dir, "scope-start.json")),
        "without a scope start only scope-end.json and the summary exist")
    say(block["start"] is None and block["start_unavailable_reason"] == reason and summary["repository"]["head_start"] is None,
        "the before-unavailable form has a null start and the stated reason", block["start_unavailable_reason"])
    say(all(c["attribution"] == "before unavailable" and c["change"] == "unknown" and c["reported"] is True
            for c in block["changed_paths"]) and [c["path"] for c in block["changed_paths"]] == ["app/settings/Panel.tsx", "lib/format.ts"],
        "changed_paths are exactly the reported paths, before unavailable, change unknown", block["changed_paths"])
    order = lambda x: (x[0], x[1] or "")
    kinds = sorted(((d["kind"], d["path"]) for d in block["discrepancies"]), key=order)
    say(kinds == sorted([("before-unavailable", None), ("outside-where", "lib/format.ts"), ("fingerprint-omitted", "big.bin"),
                          ("fingerprint-omitted", "docs/readme.md")], key=order),
        "no-start discrepancies: before-unavailable, outside-where for reported paths, omitted end entries", kinds)
    m, pasted = paste(summary, base, work)
    proc, codes = validate(wtsh, pasted, fixrun)
    say(proc.returncode == 0 and not codes, "control: the before-unavailable blocks validate", proc.stdout + proc.stderr)
    broken = copy.deepcopy(m)
    broken["scope"]["changed_paths"][0]["attribution"] = "reported-and-observed"
    json.dump(broken, open(os.path.join(work, "broken3.json"), "w"))
    proc, codes = validate(wtsh, os.path.join(work, "broken3.json"), fixrun)
    say(proc.returncode == 1 and "WT-SCOPE-START" in codes, "claiming observation without a start snapshot is rejected", sorted(codes))

elif scenario == "commit":
    run_dir, repo, wtsh, fixrun, base, work, start_head, end_head = sys.argv[2:10]
    summary = load(os.path.join(run_dir, "scope-summary.json"))
    block = summary["scope"]
    say(block["committed_changes"] == [{"path": "app/settings/Panel.tsx", "change": "modified"}],
        "a change committed between the snapshots is listed in committed_changes", block["committed_changes"])
    say(block["end"]["entries"] == [] and summary["repository"]["dirty_at_end"] is False
        and summary["repository"]["head_start"] == start_head and summary["repository"]["head_end"] == end_head,
        "the clean end snapshot does not hide the commit; both heads are recorded")
    say([(c["path"], c["change"], c["attribution"]) for c in block["changed_paths"]] ==
        [("app/settings/Panel.tsx", "modified", "reported-and-observed")], "the committed path is an observed changed path",
        block["changed_paths"])
    m, pasted = paste(summary, base, work)
    proc, codes = validate(wtsh, pasted, fixrun)
    say(proc.returncode == 0 and not codes, "control: fixture-mode validation accepts the committed-change blocks", proc.stdout + proc.stderr)
    # Run-directory mode re-derives committed_changes from the real repository.
    rundir_id = m["run"]["id"] = os.path.basename(run_dir)
    shutil.copytree(os.path.join(fixrun, "assets"), os.path.join(run_dir, "assets"))
    json.dump(m, open(os.path.join(run_dir, "manifest.json"), "w"), indent=2)
    proc = subprocess.run(["bash", wtsh, "validate", "--run-dir", run_dir], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, env=env)
    say(proc.returncode == 0, "control: run-directory mode re-derives committed_changes exactly and accepts them",
        proc.stdout + proc.stderr)
    for label, mutate in (("a wrong change type", lambda c: c[0].update(change="added")),
                          ("an extra path", lambda c: c.append({"path": "lib/format.ts", "change": "modified"})),
                          ("a missing path", lambda c: c.clear())):
        bad = copy.deepcopy(m)
        mutate(bad["scope"]["committed_changes"])
        json.dump(bad, open(os.path.join(run_dir, "manifest.json"), "w"), indent=2)
        proc = subprocess.run(["bash", wtsh, "validate", "--run-dir", run_dir], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              universal_newlines=True, env=env)
        codes = set(line.split(" ", 1)[0] for line in proc.stdout.splitlines() if line.startswith("WT-"))
        say(proc.returncode == 1 and "WT-HEAD-DRIFT" in codes, "run-directory mode rejects committed_changes with %s" % label, sorted(codes))

elif scenario == "rename":
    run_dir, wtsh, fixrun, base, work = sys.argv[2:7]
    end, summary = load(os.path.join(run_dir, "scope-end.json")), load(os.path.join(run_dir, "scope-summary.json"))
    block = summary["scope"]
    en = dict((e["path"], e) for e in end["entries"])
    old, new = en.get("docs/readme.md", {}), en.get("app/settings/readme.md", {})
    say(old.get("state") == "deleted" and old.get("omitted") == "deleted" and new.get("state") == "added"
        and new.get("sha256") is not None,
        "a staged rename keeps both paths in scope-end.json: the original as deleted, the new path as added", sorted(en))
    say(block["start"]["entries"] == [] and summary["repository"]["head_start"] == summary["repository"]["head_end"],
        "the rename is a working-tree change only: HEAD did not move and the start snapshot was clean")
    rows = dict((c["path"], c) for c in block["changed_paths"])
    got = dict((p, (c["change"], c["in_where"], c["reported"], c["attribution"])) for p, c in rows.items())
    want = {
        "docs/readme.md": ("deleted", False, False, "observed-only: attribution uncertain"),
        "app/settings/readme.md": ("added", True, True, "reported-and-observed"),
        "lib/format.ts": ("modified", False, False, "observed-only: attribution uncertain"),
    }
    say(got == want, "changed_paths hold both renamed paths: the original deleted and outside WHERE, the new path added and inside", got)
    order = lambda x: (x[0], x[1] or "")
    kinds = sorted(((d["kind"], d["path"]) for d in block["discrepancies"]), key=order)
    say(("outside-where", "docs/readme.md") in kinds and ("fingerprint-omitted", "docs/readme.md") in kinds
        and ("outside-where", "app/settings/readme.md") not in kinds,
        "the original outside WHERE is an outside-where discrepancy (control: the new path inside WHERE is not)", kinds)
    say("app/settings/theme.css" not in rows and "app/settings/theme.css" not in en and rows["lib/format.ts"]["change"] == "modified",
        "controls: an unchanged tracked file is not listed and a plain edit is modified")
    m, pasted = paste(summary, base, work)
    proc, codes = validate(wtsh, pasted, fixrun)
    say(proc.returncode == 0 and not codes, "control: the pasted blocks of a staged rename validate", proc.stdout + proc.stderr)
    hidden = copy.deepcopy(m)
    hidden["scope"]["changed_paths"] = [c for c in hidden["scope"]["changed_paths"] if c["path"] != "docs/readme.md"]
    json.dump(hidden, open(os.path.join(work, "hidden.json"), "w"))
    proc, codes = validate(wtsh, os.path.join(work, "hidden.json"), fixrun)
    say(proc.returncode == 1 and "WT-SCOPE-CHANGED" in codes,
        "a manifest that drops the renamed-away original from changed_paths is rejected", sorted(codes))

print("DONE")
PY
mkdir -p "$TMPROOT/work-main"
apply_results "scope main" < <(python3 -B "$TMPROOT/check-scope.py" main "$RUN_MAIN" "$REPO" "$HEAD_NOW" "$BRANCH_NOW" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$TMPROOT/work-main")

# No scope start: the before-unavailable form (default reason, then an explicit one).
run_wt SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES=16 -- scope end --repo "$REPO" --run wt-scope-nostart-0001 --where app/settings --reported app/settings/Panel.tsx lib/format.ts
check "scope end without a start file exits 0" "0" "$RUN_RC"
mkdir -p "$TMPROOT/work-nostart"
apply_results "scope nostart" < <(python3 -B "$TMPROOT/check-scope.py" nostart "$REPO/.tmp/walkthroughs/wt-scope-nostart-0001" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$TMPROOT/work-nostart" "scope start was not recorded")
run_wt SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES=16 -- scope end --repo "$REPO" --run wt-scope-nostart-0002 --where app/settings --reported app/settings/Panel.tsx lib/format.ts --start-unavailable-reason "started after editing"
check "scope end with an explicit reason exits 0" "0" "$RUN_RC"
mkdir -p "$TMPROOT/work-nostart2"
apply_results "scope nostart reason" < <(python3 -B "$TMPROOT/check-scope.py" nostart "$REPO/.tmp/walkthroughs/wt-scope-nostart-0002" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$TMPROOT/work-nostart2" "started after editing")

# A change committed between start and end (second repository so the first stays dirty).
REPO2="$TMPROOT/repo-commit"
make_repo "$REPO2" || fail "the second throwaway repository could not be created"
run_wt -- scope start --repo "$REPO2" --run wt-scope-commit-0001 --where app/settings
check "scope start in a clean repository exits 0" "0" "$RUN_RC"
START_HEAD=$(g "$REPO2" rev-parse HEAD)
printf 'one\ntwo\n' >"$REPO2/app/settings/Panel.tsx"
g "$REPO2" add -A && g "$REPO2" commit -q -m "change panel"
END_HEAD=$(g "$REPO2" rev-parse HEAD)
run_wt -- scope end --repo "$REPO2" --run wt-scope-commit-0001 --where app/settings --reported app/settings/Panel.tsx
check "scope end after a commit exits 0" "0" "$RUN_RC"
check "the commit moved HEAD (control for the committed-change checks)" "yes" "$([ "$START_HEAD" != "$END_HEAD" ] && echo yes || echo no)"
mkdir -p "$TMPROOT/work-commit"
apply_results "scope commit" < <(python3 -B "$TMPROOT/check-scope.py" commit "$REPO2/.tmp/walkthroughs/wt-scope-commit-0001" "$REPO2" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$TMPROOT/work-commit" "$START_HEAD" "$END_HEAD")

# A staged rename across the WHERE boundary: HEAD does not move, so the snapshots are the only evidence.
REPO7="$TMPROOT/repo-rename"
make_repo "$REPO7" || fail "the rename throwaway repository could not be created"
run_wt -- scope start --repo "$REPO7" --run wt-scope-rename-0001 --where app/settings
check "scope start before a staged rename exits 0" "0" "$RUN_RC"
g "$REPO7" mv docs/readme.md app/settings/readme.md
printf 'two\n' >"$REPO7/lib/format.ts"
run_wt -- scope end --repo "$REPO7" --run wt-scope-rename-0001 --where app/settings --reported app/settings/readme.md
check "scope end after a staged rename exits 0" "0" "$RUN_RC"
mkdir -p "$TMPROOT/work-rename"
apply_results "scope rename" < <(python3 -B "$TMPROOT/check-scope.py" rename "$REPO7/.tmp/walkthroughs/wt-scope-rename-0001" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$TMPROOT/work-rename")

# A rewritten history is refused (control above: the forward commit was accepted).
REPO3="$TMPROOT/repo-rewrite"
make_repo "$REPO3" || fail "the third throwaway repository could not be created"
run_wt -- scope start --repo "$REPO3" --run wt-scope-rewrite-0001 --where app/settings
g "$REPO3" commit -q --amend -m "rewritten"
run_wt -- scope end --repo "$REPO3" --run wt-scope-rewrite-0001 --where app/settings
check "scope end refuses a start HEAD that is not an ancestor (exit 2)" "2" "$RUN_RC"
case "$RUN_ERR" in *ancestor*) pass ;; *) fail "the ancestor refusal names the reason" "$RUN_ERR" ;; esac
check "a refused scope end writes no scope-end.json" "no" "$([ -e "$REPO3/.tmp/walkthroughs/wt-scope-rewrite-0001/scope-end.json" ] && echo yes || echo no)"

# Argument and tunable handling, each beside a control.
run_wt -- scope start --repo "$REPO" --run wt-scope-main-0001 --where app/settings
check "scope start refuses to overwrite an existing scope-start.json (exit 2)" "2" "$RUN_RC"
run_wt -- scope end --repo "$REPO" --run wt-scope-main-0001 --where app/settings --start-unavailable-reason "contradiction"
check "--start-unavailable-reason is refused when scope-start.json exists (exit 2)" "2" "$RUN_RC"
run_wt -- scope end --repo "$REPO" --run wt-scope-args-0001
check "scope end without --where is refused (exit 2)" "2" "$RUN_RC"
run_wt -- scope end --repo "$REPO" --run wt-scope-args-0001 --where app/settings
check "control: scope end with --where is accepted" "0" "$RUN_RC"
for bad in "/abs/path" "a/../b" "a//b" "a/" "./a"; do
	run_wt -- scope end --repo "$REPO" --run wt-scope-args-0002 --where "$bad"
	check "scope end refuses the path '$bad' (exit 2)" "2" "$RUN_RC"
done
run_wt -- scope end --repo "$REPO" --run Bad_Run --where app/settings
check "scope refuses an invalid run id (exit 2)" "2" "$RUN_RC"
run_wt -- scope end --repo "$REPO" --run-dir "$REPO/.tmp/walkthroughs/wt-scope-args-0003" --run wt-scope-args-0003 --where app/settings
check "--run and --run-dir together are refused (exit 2)" "2" "$RUN_RC"
run_wt -- scope start --repo "$REPO"
check "scope start without --run generates a run id" "0" "$RUN_RC"
GENERATED=$(printf '%s\n' "$RUN_OUT" | sed -n '1s/^run-dir: //p')
case "$(basename "$GENERATED")" in
wt-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]-[0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass ;;
*) fail "the generated run id has the wt-<UTC date>-<time>-<4 hex> form" "$GENERATED" ;;
esac
check "the generated run directory exists with a scope-start.json" "yes" "$([ -f "$GENERATED/scope-start.json" ] && echo yes || echo no)"
run_wt SESSION_WALKTHROUGH_OUTPUT_ROOT=.tmp/other-root -- scope start --repo "$REPO" --run wt-scope-root-0001
check "SESSION_WALKTHROUGH_OUTPUT_ROOT selects the output root (ignored root accepted)" "yes" "$([ "$RUN_RC" -eq 0 ] && [ -f "$REPO/.tmp/other-root/wt-scope-root-0001/scope-start.json" ] && echo yes || echo no)"
run_wt SESSION_WALKTHROUGH_OUTPUT_ROOT=visible/root -- scope start --repo "$REPO" --run wt-scope-root-0002
check "a non-ignored output root is refused (exit 2) and nothing is created" "2:no" "$RUN_RC:$([ -e "$REPO/visible" ] && echo yes || echo no)"
for bad in "/abs/root" "../escape" ".tmp/../up"; do
	run_wt SESSION_WALKTHROUGH_OUTPUT_ROOT="$bad" -- scope start --repo "$REPO" --run wt-scope-root-0003
	check "an output root of '$bad' is refused (exit 2)" "2" "$RUN_RC"
done
for value in "abc" "0" "-5" "1.5" ""; do
	tag="wt-scope-max-$(printf '%s' "$value" | tr -c 'a-z0-9' 'x')-1"
	run_wt SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES="$value" -- scope start --repo "$REPO" --run "$tag"
	got=$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_bytes"])' "$REPO/.tmp/walkthroughs/$tag/scope-start.json")
	check "FINGERPRINT_MAX_BYTES='$value' falls back to the default 8388608" "8388608" "$got"
done
run_wt SESSION_WALKTHROUGH_FINGERPRINT_MAX_BYTES=16 -- scope start --repo "$REPO" --run wt-scope-max-ok-1
check "control: FINGERPRINT_MAX_BYTES=16 is recorded as 16" "16" "$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1]))["max_bytes"])' "$REPO/.tmp/walkthroughs/wt-scope-max-ok-1/scope-start.json")"
REPO4="$TMPROOT/repo-fresh"
make_repo "$REPO4" || fail "the fourth throwaway repository could not be created"
rmdir "$REPO4/.tmp"
run_wt -- scope start --repo "$REPO4" --run wt-scope-fresh-0001
check "scope creates an ignored output root that does not exist yet" "yes" "$([ "$RUN_RC" -eq 0 ] && [ -f "$REPO4/.tmp/walkthroughs/wt-scope-fresh-0001/scope-start.json" ] && echo yes || echo no)"
check "scope never edits ignore rules" "$(printf '.tmp/\nignored.log\n')" "$(cat "$REPO4/.gitignore")"
check "scope leaves the repository index and HEAD alone" "" "$(g "$REPO4" status --porcelain=v1)"

# --- 10b. every snapshot state and the unusual entries ---------------------------
REPO5="$TMPROOT/repo-states"
make_repo "$REPO5" || fail "the states throwaway repository could not be created"
g "$REPO5" mv docs/readme.md docs/guide.md
g "$REPO5" rm -q lib/format.ts
printf 'one\ntwo\n' >"$REPO5/app/settings/Panel.tsx"
rm "$REPO5/app/settings/theme.css"
ln -s Panel.tsx "$REPO5/app/settings/theme.css"
printf 'new\n' >"$REPO5/staged-new.txt"
g "$REPO5" add staged-new.txt
printf 'x\n' >"$REPO5/sp ace.txt"
printf 'y\n' >"$REPO5/caf$(printf '\303\251').txt"
ln -s /nonexistent "$REPO5/dangling-link"
mkdir "$REPO5/nested"
g "$REPO5/nested" init -q 2>/dev/null
printf 'z\n' >"$REPO5/nested/f"
printf 's\n' >"$REPO5/unreadable.txt"
chmod 000 "$REPO5/unreadable.txt"
run_wt -- scope start --repo "$REPO5" --run wt-states-0001
check "scope start over every state exits 0" "0" "$RUN_RC"
chmod 644 "$REPO5/unreadable.txt"
run_wt -- scope start --repo "$REPO5" --run wt-states-0002
check "control: once readable, the same file is hashed (second snapshot)" "0" "$RUN_RC"
cat >"$TMPROOT/check-states.py" <<'PY'
import hashlib, json, os, sys

repo, first, second = sys.argv[1:4]


def say(ok, text, detail=""):
    print("PASS\t" + text if ok else "FAIL\t%s\t%s" % (text, str(detail).replace("\n", " | ")[:400]))


raw = open(first, "rb").read()
entries = dict((e["path"], e) for e in json.loads(raw)["entries"])
say(all(byte < 128 for byte in raw), "snapshot JSON is plain ASCII even for a non-ASCII file name")
cafe = "caf" + chr(0xE9) + ".txt"
expected = {
    "app/settings/Panel.tsx": ("modified", None),
    "app/settings/theme.css": ("type-changed", "type"),
    "lib/format.ts": ("deleted", "deleted"),
    "docs/guide.md": ("added", None),
    "docs/readme.md": ("deleted", "deleted"),
    "staged-new.txt": ("added", None),
    "sp ace.txt": ("untracked", None),
    cafe: ("untracked", None),
    "dangling-link": ("untracked", "type"),
    "nested": ("untracked", "type"),
}
got = dict((p, (e["state"], e.get("omitted"))) for p, e in entries.items() if p != "unreadable.txt")
say(got == expected, "each git status state maps to modified, added, deleted, type-changed or untracked (a staged rename is a deletion plus an addition)", got)
old, new = entries.get("docs/readme.md", {}), entries.get("docs/guide.md", {})
say(old.get("state") == "deleted" and old.get("omitted") == "deleted" and old.get("sha256") is None
    and new.get("state") == "added" and "omitted" not in new and new.get("sha256") is not None,
    "a staged rename keeps both paths: the original as deleted (omitted: deleted), the new path as added and hashed", (old, new))
say(".gitignore" not in entries and entries.get("app/settings/Panel.tsx", {}).get("state") == "modified",
    "control: an unchanged tracked file is not listed and a plain edit is modified")
say("nested/f" not in entries and "nested/" not in entries, "a nested repository is one omitted: type entry without a trailing slash or contents")
hashed = [p for p, e in entries.items() if "omitted" not in e]
say(all(entries[p]["sha256"] == hashlib.sha256(open(os.path.join(repo, p), "rb").read()).hexdigest() for p in hashed),
    "control: every entry without omitted carries the true digest of the file", hashed)
if os.geteuid() == 0:
    say(True, "unreadable-file check skipped: running as root can read a mode 000 file")
else:
    say(entries["unreadable.txt"].get("omitted") == "unreadable" and entries["unreadable.txt"]["sha256"] is None,
        "an unreadable file is omitted: unreadable", entries["unreadable.txt"])
later = dict((e["path"], e) for e in json.load(open(second))["entries"])
say(later["unreadable.txt"]["sha256"] == hashlib.sha256(b"s\n").hexdigest() and "omitted" not in later["unreadable.txt"],
    "control: after chmod the same file is hashed")
print("DONE")
PY
apply_results "snapshot states" < <(python3 -B "$TMPROOT/check-states.py" "$REPO5" "$REPO5/.tmp/walkthroughs/wt-states-0001/scope-start.json" "$REPO5/.tmp/walkthroughs/wt-states-0002/scope-start.json")
cat >"$TMPROOT/check-parse.py" <<'PY'
import importlib.util, sys
from wtlib import say

spec = importlib.util.spec_from_file_location("wt", sys.argv[1])
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
parse = wt.parse_status
say(parse(b"A  new.txt\0D  old.txt\0") == [("A ", "new.txt"), ("D ", "old.txt")],
    "control: --no-renames output, a deletion and an addition, reads as two records")
say(parse(b" M plain.txt\0") == [(" M", "plain.txt")] and parse(b"") == [], "control: a plain edit and an empty status read unchanged")
say(parse(b"R  new.txt\0old.txt\0") == [("A ", "new.txt"), ("D ", "old.txt")],
    "a rename record that still appears keeps both paths: the new one as an addition, the original as a deletion")
say(parse(b"RM new.txt\0old.txt\0 M other.txt\0") == [("A ", "new.txt"), ("D ", "old.txt"), (" M", "other.txt")],
    "the record after a rename is read from the right offset")
say(parse(b"C  copy.txt\0src.txt\0") == [("A ", "copy.txt")],
    "a copy keeps its new path as an addition and invents no deletion of the source")
try:
    parse(b"R  new.txt\0")
    say(False, "a rename record without its original path is refused")
except wt.Unusable:
    say(True, "a rename record without its original path is refused")
say(wt.map_state("A ") == "added" and wt.map_state("D ") == "deleted" and wt.map_state(" M") == "modified",
    "the split records map to added and deleted (control: a plain edit is modified)")
print("DONE")
PY
apply_results "status parser" < <(python3 -B "$TMPROOT/check-parse.py" "$HERE/walkthrough.py")
# an unborn HEAD is refused, leaves nothing behind, and works once a commit exists
REPO6="$TMPROOT/repo-unborn"
mkdir -p "$REPO6"
g "$REPO6" init -q 2>/dev/null
g "$REPO6" config user.name "Walkthrough Test"
g "$REPO6" config user.email "walkthrough-test@example.invalid"
printf '.tmp/\n' >"$REPO6/.gitignore"
run_wt -- scope start --repo "$REPO6" --run wt-unborn-0001
check "a repository without a commit is refused (exit 2) and no run directory is left behind" "2:no" "$RUN_RC:$([ -e "$REPO6/.tmp" ] && echo yes || echo no)"
g "$REPO6" add -A && g "$REPO6" commit -q -m "first"
run_wt -- scope start --repo "$REPO6" --run wt-unborn-0001
check "control: the same command succeeds once HEAD exists" "0" "$RUN_RC"

# --- 11. containment -----------------------------------------------------------
# outside the repository
run_wt -- scope start --repo "$REPO" --run-dir "$TMPROOT/outside/wt-outside-0001"
check "a run directory outside the repository is refused (exit 2) and not created" "2:no" "$RUN_RC:$([ -e "$TMPROOT/outside" ] && echo yes || echo no)"
run_wt -- scope start --repo "$REPO" --run-dir "$REPO/.tmp/walkthroughs/wt-inside-0001"
check "control: a run directory inside the ignored root is accepted" "0" "$RUN_RC"
# inside the repository but not ignored
run_wt -- scope start --repo "$REPO" --run-dir "$REPO/visible/wt-visible-0001"
check "a run directory that git does not ignore is refused (exit 2) and not created" "2:no" "$RUN_RC:$([ -e "$REPO/visible" ] && echo yes || echo no)"
case "$RUN_ERR" in *ignore*) pass ;; *) fail "the not-ignored refusal names git check-ignore" "$RUN_ERR" ;; esac
# symlink component, to a place outside the repository and to one inside it
mkdir -p "$TMPROOT/elsewhere" "$REPO/.tmp/real"
ln -s "$TMPROOT/elsewhere" "$REPO/.tmp/link-out"
ln -s "$REPO/.tmp/real" "$REPO/.tmp/link-in"
run_wt -- scope start --repo "$REPO" --run-dir "$REPO/.tmp/link-out/wt-linkout-0001"
check "a symlink component leading outside the repository is refused (exit 2); nothing is written there" "2:" "$RUN_RC:$(ls -A "$TMPROOT/elsewhere")"
run_wt -- scope start --repo "$REPO" --run-dir "$REPO/.tmp/link-in/wt-linkin-0001"
check "a symlink component leading to another ignored directory is refused too (exit 2)" "2:" "$RUN_RC:$(ls -A "$REPO/.tmp/real")"
run_wt -- scope start --repo "$REPO" --run-dir "$REPO/.tmp/real/wt-real-0001"
check "control: the real directory behind the symlink is accepted" "0" "$RUN_RC"
# the repository itself reached through a symlink is fine; links below it are not
ln -s "$REPO" "$TMPROOT/repo-alias"
run_wt -- scope start --repo "$TMPROOT/repo-alias" --run wt-alias-0001
check "control: --repo given through a symlink resolves to the real work tree" "0" "$RUN_RC"
# the run directory itself is the repository root
run_wt -- scope start --repo "$REPO" --run-dir "$REPO"
check "the repository root is not a valid run directory (exit 2)" "2" "$RUN_RC"
# assets: tampered, symlinked, special and missing files, each with its untouched control
for case_name in control tampered symlinked fifo missing assets-link; do
	work="$TMPROOT/assets-$case_name"
	cp -R "$FIX/run" "$work"
	case "$case_name" in
	tampered) python3 -B -c 'import sys; p=sys.argv[1]; d=bytearray(open(p,"rb").read()); d[-1]^=1; open(p,"wb").write(bytes(d))' "$work/assets/after.png" ;;
	symlinked) cp "$work/assets/after.png" "$TMPROOT/identical-after.png" && rm "$work/assets/after.png" && ln -s "$TMPROOT/identical-after.png" "$work/assets/after.png" ;;
	fifo) rm "$work/assets/after.png" && mkfifo "$work/assets/after.png" ;;
	missing) rm "$work/assets/after.png" ;;
	assets-link) mv "$work/assets" "$TMPROOT/moved-assets" && ln -s "$TMPROOT/moved-assets" "$work/assets" ;;
	esac
	run_wt -- validate --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$work"
	codes=$(printf '%s\n' "$RUN_OUT" | sed -n 's/^\(WT-[A-Z-]*\) .*/\1/p' | sort -u | tr '\n' ' ')
	case "$case_name" in
	control) check "asset control: an untouched copy of the fixture run directory validates" "0:" "$RUN_RC:$codes" ;;
	tampered) check "a one-byte change to after.png is reported as WT-ASSET-HASH only" "1:WT-ASSET-HASH " "$RUN_RC:$codes" ;;
	symlinked) check "a symlinked asset is refused as WT-ASSET-PATH although its bytes are identical" "1:WT-ASSET-PATH " "$RUN_RC:$codes" ;;
	fifo) check "a FIFO in place of an asset is refused as WT-ASSET-PATH without hanging" "1:WT-ASSET-PATH " "$RUN_RC:$codes" ;;
	missing) check "a missing asset file is WT-ASSET-PATH (exit 1, not an input error)" "1:WT-ASSET-PATH " "$RUN_RC:$codes" ;;
	assets-link) check "an assets directory that is a symlink is refused as WT-ASSET-PATH" "1:WT-ASSET-PATH " "$RUN_RC:$codes" ;;
	esac
done
# the manifest itself: symlink, FIFO and non-UTF-8, each beside the regular file
cp "$FIX/manifests/valid-synthetic.json" "$TMPROOT/manifest-regular.json"
run_wt -- validate --manifest "$TMPROOT/manifest-regular.json" --run-dir "$FIX/run"
check "control: a regular manifest file is accepted" "0" "$RUN_RC"
ln -s "$TMPROOT/manifest-regular.json" "$TMPROOT/manifest-link.json"
run_wt -- validate --manifest "$TMPROOT/manifest-link.json" --run-dir "$FIX/run"
check "a manifest that is a symlink is refused (exit 2)" "2" "$RUN_RC"
mkfifo "$TMPROOT/manifest-fifo.json"
run_wt -- validate --manifest "$TMPROOT/manifest-fifo.json" --run-dir "$FIX/run"
check "a manifest that is a FIFO is refused (exit 2) without hanging" "2" "$RUN_RC"
printf '\377\376{}' >"$TMPROOT/manifest-binary.json"
run_wt -- validate --manifest "$TMPROOT/manifest-binary.json" --run-dir "$FIX/run"
check "a manifest with a bad encoding is refused (exit 2)" "2" "$RUN_RC"
printf '{"schema_version": 1,' >"$TMPROOT/manifest-truncated.json"
run_wt -- validate --manifest "$TMPROOT/manifest-truncated.json" --run-dir "$FIX/run"
check "a manifest that is not JSON is refused (exit 2)" "2" "$RUN_RC"
run_wt -- validate --manifest "$TMPROOT/manifest-regular.json" --run-dir "$TMPROOT/no-such-run-dir"
check "a missing run directory is refused (exit 2)" "2" "$RUN_RC"
printf '{"schema_version": 1, "n": NaN}' >"$TMPROOT/manifest-nan.json"
run_wt -- validate --manifest "$TMPROOT/manifest-nan.json" --run-dir "$FIX/run"
check "a non-finite number is rejected before any other check (exit 1, WT-JSON-DUPLICATE-KEY)" "1:yes" "$RUN_RC:$(printf '%s\n' "$RUN_OUT" | grep -q '^WT-JSON-DUPLICATE-KEY' && echo yes || echo no)"
printf '{"schema_version": 1, "n": 1}' >"$TMPROOT/manifest-finite.json"
run_wt -- validate --manifest "$TMPROOT/manifest-finite.json" --run-dir "$FIX/run"
check "control: the same document with a finite number gets past the strict-JSON check" "1:no" "$RUN_RC:$(printf '%s\n' "$RUN_OUT" | grep -q '^WT-JSON-DUPLICATE-KEY' && echo yes || echo no)"

# --- 12. run-directory lock ----------------------------------------------------
LOCKRUN="$REPO/.tmp/walkthroughs/wt-lock-0001"
mkdir -p "$LOCKRUN/.lock"
sh -c 'echo $$ >"$1"; exec sleep 60' _ "$LOCKRUN/.lock/pid" &
HOLDER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	[ -s "$LOCKRUN/.lock/pid" ] && break
	sleep 0.1
done
check "the test holder wrote its own pid into .lock/pid" "$HOLDER_PID" "$(tr -d '[:space:]' <"$LOCKRUN/.lock/pid")"
STARTED=$SECONDS
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=1 -- scope start --repo "$REPO" --run-dir "$LOCKRUN"
ELAPSED=$((SECONDS - STARTED))
check "a live holder makes scope refuse (exit 2) within the timeout" "2:yes" "$RUN_RC:$([ "$ELAPSED" -le 6 ] && echo yes || echo no)"
case "$RUN_ERR" in *"could not lock"*"$HOLDER_PID"*) pass ;; *) fail "the lock refusal names the holder pid" "$RUN_ERR" ;; esac
check "the live holder's lock is left intact and nothing was written" "$HOLDER_PID:no" "$(tr -d '[:space:]' <"$LOCKRUN/.lock/pid"):$([ -e "$LOCKRUN/scope-start.json" ] && echo yes || echo no)"
kill "$HOLDER_PID" 2>/dev/null
wait "$HOLDER_PID" 2>/dev/null
HOLDER_PID=""
# a dead holder is reclaimed
rm -rf "$LOCKRUN/.lock"
mkdir -p "$LOCKRUN/.lock"
sleep 0 &
DEAD_PID=$!
wait "$DEAD_PID"
printf '%s\n' "$DEAD_PID" >"$LOCKRUN/.lock/pid"
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=5 -- scope start --repo "$REPO" --run-dir "$LOCKRUN"
check "a dead holder's lock is reclaimed and the run succeeds" "0:yes" "$RUN_RC:$([ -f "$LOCKRUN/scope-start.json" ] && echo yes || echo no)"
check "the reclaimed lock is released after the run (.lock is gone)" "no" "$([ -e "$LOCKRUN/.lock" ] && echo yes || echo no)"
# an interrupted acquire (no pid file) and an unsafe lock
mkdir -p "$LOCKRUN/.lock"
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=1 -- scope end --repo "$REPO" --run-dir "$LOCKRUN" --where app/settings
check "a lock without a holder pid is refused after the timeout (exit 2)" "2" "$RUN_RC"
case "$RUN_ERR" in *"no holder pid"*) pass ;; *) fail "the refusal explains the missing holder pid" "$RUN_ERR" ;; esac
rmdir "$LOCKRUN/.lock"
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=1 -- scope end --repo "$REPO" --run-dir "$LOCKRUN" --where app/settings
check "control: with the stray lock removed the same command succeeds" "0" "$RUN_RC"
ln -s "$TMPROOT/elsewhere" "$LOCKRUN/.lock"
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=1 -- scope end --repo "$REPO" --run-dir "$LOCKRUN" --where app/settings
check "a lock that is a symlink is refused as unsafe (exit 2)" "2" "$RUN_RC"
case "$RUN_ERR" in *unsafe*) pass ;; *) fail "the refusal calls the lock unsafe" "$RUN_ERR" ;; esac
rm "$LOCKRUN/.lock"
# render holds the same lock while it reads, validates and writes (its run directory is contained like any other)
mkdir -p "$REPO/.tmp/walkthroughs"
RLOCK="$REPO/.tmp/walkthroughs/wt-render-lock-0001"
cp -R "$FIX/run" "$RLOCK"
mkdir "$RLOCK/.lock"
sh -c 'echo $$ >"$1"; exec sleep 60' _ "$RLOCK/.lock/pid" &
HOLDER_PID=$!
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
	[ -s "$RLOCK/.lock/pid" ] && break
	sleep 0.1
done
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=1 -- render --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$RLOCK"
check "render refuses while a live holder has the run lock (exit 2) and writes no page" "2:no" "$RUN_RC:$([ -e "$RLOCK/index.html" ] && echo yes || echo no)"
kill "$HOLDER_PID" 2>/dev/null
wait "$HOLDER_PID" 2>/dev/null
HOLDER_PID=""
rm -rf "$RLOCK/.lock"
run_wt SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS=1 -- render --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$RLOCK"
check "control: with the lock gone the same render writes the page and releases the lock" "0:yes:no" "$RUN_RC:$([ -f "$RLOCK/index.html" ] && echo yes || echo no):$([ -e "$RLOCK/.lock" ] && echo yes || echo no)"
check "no lock directory is left in any run directory the suite used" "" "$(find "$TMPROOT" -name .lock -type d 2>/dev/null)"

# --- 12b. concurrent writers and an unusable repository --------------------------
RACE_PIDS=""
for racer in 1 2 3 4; do
	(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash "$WTSH" scope start --repo "$REPO" --run wt-race-0001 >/dev/null 2>&1
		echo $? >"$TMPROOT/race-$racer") &
	RACE_PIDS="$RACE_PIDS $!"
done
for racer_pid in $RACE_PIDS; do wait "$racer_pid"; done
RACE_CODES=$(cat "$TMPROOT"/race-[1-4] | sort | uniq -c | tr -s ' ' | tr '\n' ';')
check "four simultaneous scope start calls on one run: exactly one succeeds, three are refused" " 1 0; 3 2;" "$RACE_CODES"
check "the race leaves one scope-start.json and no lock" "yes:no" "$([ -f "$REPO/.tmp/walkthroughs/wt-race-0001/scope-start.json" ] && echo yes || echo no):$([ -e "$REPO/.tmp/walkthroughs/wt-race-0001/.lock" ] && echo yes || echo no)"
mkdir -p "$TMPROOT/not-a-repo"
run_wt -- scope start --repo "$TMPROOT/not-a-repo" --run wt-norepo-0001
check "a directory that is not a git work tree is refused (exit 2) and nothing is created" "2:no" "$RUN_RC:$([ -e "$TMPROOT/not-a-repo/.tmp" ] && echo yes || echo no)"

# --- 12c. descriptor override and the schema evaluator's fail-closed behaviour ----
cp -R "$HERE/descriptors" "$TMPROOT/descriptors-ok"
run_wt -- validate --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$FIX/run" --descriptors "$TMPROOT/descriptors-ok"
check "control: --descriptors with a full copy of the shipped descriptors validates" "0" "$RUN_RC"
cp -R "$HERE/descriptors" "$TMPROOT/descriptors-missing"
rm "$TMPROOT/descriptors-missing/web-chrome-devtools.json"
run_wt -- validate --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$FIX/run" --descriptors "$TMPROOT/descriptors-missing"
check "--descriptors without the web descriptor reports WT-ADAPTER-UNKNOWN (exit 1)" "1:yes" "$RUN_RC:$(printf '%s\n' "$RUN_OUT" | grep -q '^WT-ADAPTER-UNKNOWN' && echo yes || echo no)"
cp -R "$HERE/descriptors" "$TMPROOT/descriptors-dup"
printf '{"schema_version": 1, "schema_version": 1}' >"$TMPROOT/descriptors-dup/web-chrome-devtools.json"
run_wt -- validate --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$FIX/run" --descriptors "$TMPROOT/descriptors-dup"
check "a descriptor with a duplicate key is refused by the strict reader (exit 2)" "2" "$RUN_RC"
cp -R "$HERE/descriptors" "$TMPROOT/descriptors-bad-id"
mv "$TMPROOT/descriptors-bad-id/web-chrome-devtools.json" "$TMPROOT/descriptors-bad-id/renamed-descriptor.json"
run_wt -- validate --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$FIX/run" --descriptors "$TMPROOT/descriptors-bad-id"
check "a descriptor whose id differs from its file name is refused (exit 2)" "2" "$RUN_RC"
run_wt -- validate --manifest "$FIX/manifests/valid-synthetic.json" --run-dir "$FIX/run" --descriptors "$TMPROOT/no-such-descriptors"
check "a missing descriptors directory is refused (exit 2)" "2" "$RUN_RC"
cat >"$TMPROOT/check-evaluator.py" <<'PY'
import importlib.util, sys

spec = importlib.util.spec_from_file_location("wt", sys.argv[1])
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)


def say(ok, text, detail=""):
    print("PASS\t" + text if ok else "FAIL\t%s\t%s" % (text, str(detail)[:300]))


def valid(schema, instance):
    return not wt.SchemaEvaluator(schema).validate(instance)


I = {"type": "integer"}
cases = [
    ("integer accepts 1", I, 1, True), ("integer accepts 1.0", I, 1.0, True),
    ("integer rejects 1.5", I, 1.5, False), ("integer rejects true", I, True, False),
    ("number accepts 2.5", {"type": "number"}, 2.5, True), ("number rejects true", {"type": "number"}, True, False),
    ("const 1 accepts 1", {"const": 1}, 1, True), ("const 1 rejects true", {"const": 1}, True, False),
    ("const null accepts null", {"const": None}, None, True), ("const null rejects 0", {"const": None}, 0, False),
    ("enum accepts a member", {"enum": ["a", "b"]}, "a", True), ("enum rejects a non-member", {"enum": ["a", "b"]}, "c", False),
    ("pattern is a full match", {"type": "string", "pattern": "^a+$"}, "aaa", True),
    ("pattern rejects a trailing newline", {"type": "string", "pattern": "^a+$"}, "aaa\n", False),
    ("required accepts the key", {"type": "object", "required": ["k"]}, {"k": 1}, True),
    ("required rejects a missing key", {"type": "object", "required": ["k"]}, {}, False),
    ("additionalProperties false rejects an extra key", {"type": "object", "additionalProperties": False, "properties": {"a": I}}, {"a": 1, "b": 2}, False),
    ("additionalProperties false accepts only known keys", {"type": "object", "additionalProperties": False, "properties": {"a": I}}, {"a": 1}, True),
    ("additionalProperties as a schema accepts matching values", {"type": "object", "additionalProperties": I}, {"a": 1}, True),
    ("additionalProperties as a schema rejects others", {"type": "object", "additionalProperties": I}, {"a": "x"}, False),
    ("oneOf accepts exactly one match", {"oneOf": [{"type": "string"}, {"type": "null"}]}, None, True),
    ("oneOf rejects no match", {"oneOf": [{"type": "string"}, {"type": "null"}]}, 1, False),
    ("oneOf rejects two matches", {"oneOf": [{"type": "integer"}, {"type": "number"}]}, 1, False),
    ("minItems accepts one item", {"type": "array", "minItems": 1}, [1], True), ("minItems rejects none", {"type": "array", "minItems": 1}, [], False),
    ("uniqueItems keeps 1 and true distinct", {"type": "array", "uniqueItems": True}, [1, True], True),
    ("uniqueItems rejects 1 and 1.0", {"type": "array", "uniqueItems": True}, [1, 1.0], False),
    ("minProperties rejects an empty object", {"type": "object", "minProperties": 1}, {}, False),
    ("exclusiveMinimum rejects the bound", {"exclusiveMinimum": 0}, 0, False), ("exclusiveMinimum accepts above", {"exclusiveMinimum": 0}, 0.1, True),
    ("maximum rejects above", {"maximum": 180}, 240, False), ("maximum accepts the bound", {"maximum": 180}, 180, True),
    ("minLength counts code points", {"type": "string", "minLength": 2}, chr(0x1F600) + "a", True),
    ("maxLength rejects a longer string", {"type": "string", "maxLength": 2}, "abc", False),
    ("$ref resolves a definition", {"definitions": {"x": I}, "properties": {"a": {"$ref": "#/definitions/x"}}}, {"a": 1}, True),
    ("$ref applies the definition", {"definitions": {"x": I}, "properties": {"a": {"$ref": "#/definitions/x"}}}, {"a": "no"}, False),
]
for text, schema, instance, want in cases:
    got = valid(schema, instance)
    say(got is want, "evaluator: " + text, "got %s" % got)
fail_closed = [
    {"format": "date-time"}, {"patternProperties": {}}, {"not": {}}, {"if": {}}, {"contains": {}},
    {"propertyNames": {}}, {"dependencies": {}}, {"multipleOf": 2}, {"type": "string", "pattern": "a+"},
    {"$ref": "http://example.invalid/x"}, {"$ref": "#/definitions/missing"},
]
for schema in fail_closed:
    try:
        wt.SchemaEvaluator(schema).validate("x")
        say(False, "evaluator stops on %s instead of passing" % schema)
    except wt.Unusable:
        say(True, "evaluator stops on %s instead of passing" % schema)
say(valid({"type": "string"}, "x"), "control: a supported schema does not raise")
say(wt.pointer([]) == "/" and wt.pointer(["a/b", "c~d", 0]) == "/a~1b/c~0d/0", "JSON pointers escape ~ and /, the root is shown as /")
print("DONE")
PY
apply_results "schema evaluator" < <(python3 -B "$TMPROOT/check-evaluator.py" "$HERE/walkthrough.py")

# --- 12d. lock first, then read: render and scope look at the run only while they hold its lock ---
# Each case starts the helper behind a live holder, proves the helper is still waiting after half
# a second, changes the run (or the place it lives in) during that wait, then releases the lock.
REPOO="$TMPROOT/repo-order"
make_repo "$REPOO" || fail "the lock-order throwaway repository could not be created"
cat >"$TMPROOT/check-order.py" <<'PY'
import json, os, subprocess, sys, time
import wtlib
from wtlib import say, build_run, head_at

wtsh, fixrun, base, repo, head = sys.argv[1:6]
shas = {head_at(base, "end"): head}
env = dict(wtlib.ENV, SESSION_WALKTHROUGH_LOCK_TIMEOUT_SECS="60")
IGNORE = os.path.join(repo, ".gitignore")
IGNORE_TEXT = ".tmp/\nignored.log\n"


def hold(run_dir):
    """A live lock holder: .lock/pid names a sleeping process this checker owns."""
    lock = os.path.join(run_dir, ".lock")
    os.mkdir(lock)
    pid_file = os.path.join(lock, "pid")
    holder = subprocess.Popen(["sh", "-c", 'echo $$ >"$1"; exec sleep 120', "_", pid_file])
    for _ in range(100):
        try:
            if open(pid_file).read().strip() == str(holder.pid):
                break
        except (IOError, OSError):
            pass
        time.sleep(0.05)
    return holder


def waits(proc, run_dir, seconds=0.5):
    """True when the helper ran for at least `seconds` and is still alive while the lock exists."""
    begin = time.monotonic()
    while time.monotonic() - begin < seconds:
        if proc.poll() is not None:
            return False
        time.sleep(0.05)
    return proc.poll() is None and os.path.isdir(os.path.join(run_dir, ".lock"))


def blocked(args, run_dir, during=None):
    """Run a helper behind a live lock; call during() while it waits; release the lock; wait for it.

    Returns (waited, returncode, stdout, stderr).
    """
    holder = hold(run_dir)
    try:
        proc = subprocess.Popen(["bash", wtsh] + args, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                universal_newlines=True, env=env)
        waited = waits(proc, run_dir)
        if during is not None:
            during(run_dir)
    finally:
        holder.kill()
        holder.wait()
    try:
        out, err = proc.communicate(timeout=60)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        return waited, -1, out, err
    return waited, proc.returncode, out, err


def flip_asset(run_dir):
    path = os.path.join(run_dir, "assets", "after.png")
    data = bytearray(open(path, "rb").read())
    data[-1] ^= 1
    open(path, "wb").write(bytes(data))


def break_manifest(run_dir):
    with open(os.path.join(run_dir, "manifest.json"), "w") as stream:
        json.dump({"schema_version": 2}, stream)


def write_ignore(text):
    """Replace .gitignore atomically, so a waiting helper never sees a half-written file."""
    with open(IGNORE + ".new", "w") as stream:
        stream.write(text)
    os.replace(IGNORE + ".new", IGNORE)


def unignore(run_dir):
    write_ignore("ignored.log\n")


def same_ignore(run_dir):
    write_ignore(IGNORE_TEXT)


def fresh(name):
    return build_run(repo, fixrun, base, "wt-order-" + name, shas)


def page_of(run_dir):
    return os.path.join(run_dir, "index.html")


def idle(run_dir):
    return not os.path.exists(os.path.join(run_dir, ".lock"))


# render: the evidence changes while render waits, so the page must follow the new evidence
run_dir = fresh("asset-0001")
waited, rc, out, err = blocked(["render", "--run-dir", run_dir], run_dir, flip_asset)
say(waited, "render is still waiting for the live lock after 0.5 s (the asset is changed while it waits)")
say(rc == 1 and "WT-ASSET-HASH" in out and not os.path.exists(page_of(run_dir)) and idle(run_dir),
    "an asset changed during the wait is caught: render exits 1 with WT-ASSET-HASH, writes no page and frees the lock",
    "rc=%d %s %s" % (rc, out, err))
run_dir = fresh("asset-0002")
waited, rc, out, err = blocked(["render", "--run-dir", run_dir], run_dir)
say(waited and rc == 0 and os.path.isfile(page_of(run_dir)) and idle(run_dir),
    "control: the same wait without a change renders (exit 0) and frees the lock", "waited=%s rc=%d %s %s" % (waited, rc, out, err))
proc = wtlib.run(wtsh, ["validate", "--run-dir", run_dir])
say(proc.returncode == 0, "control: validate accepts the run that the page was rendered from", proc.stdout + proc.stderr)

run_dir = fresh("manifest-0001")
waited, rc, out, err = blocked(["render", "--run-dir", run_dir], run_dir, break_manifest)
say(waited and rc == 1 and "WT-SCHEMA-VERSION" in out and not os.path.exists(page_of(run_dir)) and idle(run_dir),
    "a manifest replaced during the wait is read after it: render exits 1 with WT-SCHEMA-VERSION and writes no page",
    "waited=%s rc=%d %s %s" % (waited, rc, out, err))

# render and scope: the place changes while they wait, so the location is checked again once they hold the lock
run_dir = fresh("place-0001")
waited, rc, out, err = blocked(["render", "--run-dir", run_dir], run_dir, unignore)
same_ignore(run_dir)
say(waited and rc == 2 and "ignore" in err and not os.path.exists(page_of(run_dir)) and idle(run_dir),
    "render checks containment again after the wait: an output root that stops being ignored is refused (exit 2, no page)",
    "waited=%s rc=%d %s %s" % (waited, rc, out, err))
run_dir = fresh("place-0002")
waited, rc, out, err = blocked(["render", "--run-dir", run_dir], run_dir, same_ignore)
say(waited and rc == 0 and os.path.isfile(page_of(run_dir)),
    "control: replacing .gitignore with identical rules during the wait does not stop render", "waited=%s rc=%d %s %s" % (waited, rc, out, err))
scope_dir = os.path.join(repo, ".tmp", "walkthroughs", "wt-order-scope-0001")
os.makedirs(scope_dir)
waited, rc, out, err = blocked(["scope", "start", "--repo", repo, "--run-dir", scope_dir], scope_dir, unignore)
same_ignore(scope_dir)
say(waited and rc == 2 and "ignore" in err and not os.path.exists(os.path.join(scope_dir, "scope-start.json")) and idle(scope_dir),
    "scope checks containment again after the wait: an output root that stops being ignored is refused (exit 2, nothing written)",
    "waited=%s rc=%d %s %s" % (waited, rc, out, err))
scope_dir = os.path.join(repo, ".tmp", "walkthroughs", "wt-order-scope-0002")
os.makedirs(scope_dir)
waited, rc, out, err = blocked(["scope", "start", "--repo", repo, "--run-dir", scope_dir], scope_dir, same_ignore)
say(waited and rc == 0 and os.path.isfile(os.path.join(scope_dir, "scope-start.json")) and idle(scope_dir),
    "control: the same scope wait with identical ignore rules records the snapshot", "waited=%s rc=%d %s %s" % (waited, rc, out, err))
print("DONE")
PY
apply_results "lock order" < <(python3 -B "$TMPROOT/check-order.py" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$REPOO" "$(g "$REPOO" rev-parse HEAD)")

# --- 13. run-directory mode ----------------------------------------------------
cat >"$TMPROOT/check-rundir.py" <<'PY'
import copy, json, os, shutil, subprocess, sys

wtsh, fixrun, base, repo, tmproot, head = sys.argv[1:7]
env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")


def say(ok, text, detail=""):
    if ok:
        print("PASS\t" + text)
    else:
        print("FAIL\t%s\t%s" % (text, str(detail).replace("\t", " ").replace("\n", " | ")[:400]))


def validate(run_dir):
    proc = subprocess.run(["bash", wtsh, "validate", "--run-dir", run_dir], stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True, env=env)
    return proc, set(line.split(" ", 1)[0] for line in proc.stdout.splitlines() if line.startswith("WT-"))


def place(parent, name, run_id):
    # Run-directory mode checks the history in the repository, so the fixture's synthetic head
    # becomes the repository's real HEAD at every site (scope, repository and receipt).
    text = open(base).read()
    manifest = json.loads(text.replace(json.loads(text)["scope"]["end"]["head"], head))
    manifest["run"]["id"] = run_id
    target = os.path.join(parent, name)
    os.makedirs(parent, exist_ok=True)
    shutil.copytree(os.path.join(fixrun, "assets"), os.path.join(target, "assets"))
    json.dump(manifest, open(os.path.join(target, "manifest.json"), "w"), indent=2)
    return target


good = place(os.path.join(repo, ".tmp", "walkthroughs"), "wt-runmode-0001", "wt-runmode-0001")
proc, codes = validate(good)
say(proc.returncode == 0 and not codes, "control: manifest.json in <repo>/.tmp/walkthroughs/<run.id>/ validates in run-directory mode",
    proc.stdout + proc.stderr)
wrong = place(os.path.join(repo, ".tmp", "walkthroughs"), "wt-other-name-0001", "wt-runmode-0001")
proc, codes = validate(wrong)
say(proc.returncode == 1 and {"WT-RUN-ID", "WT-OUTPUT-CONTAINMENT"} <= codes,
    "a directory named differently from run.id fails WT-RUN-ID and WT-OUTPUT-CONTAINMENT", sorted(codes))
visible = place(os.path.join(repo, "visible"), "wt-runmode-0001", "wt-runmode-0001")
proc, codes = validate(visible)
say(proc.returncode == 1 and "WT-OUTPUT-CONTAINMENT" in codes and "WT-RUN-ID" not in codes,
    "a run directory that git does not ignore fails WT-OUTPUT-CONTAINMENT only", sorted(codes))
norepo = place(os.path.join(tmproot, "no-repo"), "wt-runmode-0001", "wt-runmode-0001")
proc, codes = validate(norepo)
say(proc.returncode == 1 and "WT-OUTPUT-CONTAINMENT" in codes, "a run directory outside any git repository fails WT-OUTPUT-CONTAINMENT", sorted(codes))
os.symlink(os.path.join(repo, ".tmp", "walkthroughs"), os.path.join(repo, ".tmp", "linked-root"))
proc, codes = validate(os.path.join(repo, ".tmp", "linked-root", "wt-runmode-0001"))
say(proc.returncode == 1 and "WT-OUTPUT-CONTAINMENT" in codes and "WT-RUN-ID" not in codes,
    "a symlink component in the run directory path fails WT-OUTPUT-CONTAINMENT only", sorted(codes))
bad_id = place(os.path.join(repo, ".tmp", "walkthroughs"), "Bad_Run_Id", "Bad_Run_Id")
proc, codes = validate(bad_id)
say(proc.returncode == 1 and "WT-RUN-ID" in codes, "a run id outside the grammar fails WT-RUN-ID", sorted(codes))
manifest_link = place(os.path.join(repo, ".tmp", "walkthroughs"), "wt-runmode-0002", "wt-runmode-0002")
shutil.move(os.path.join(manifest_link, "manifest.json"), os.path.join(tmproot, "moved-manifest.json"))
os.symlink(os.path.join(tmproot, "moved-manifest.json"), os.path.join(manifest_link, "manifest.json"))
proc, codes = validate(manifest_link)
say(proc.returncode == 2, "run-directory mode refuses a manifest.json that is a symlink (exit 2)", proc.stderr)
print("DONE")
PY
apply_results "run directory mode" < <(python3 -B "$TMPROOT/check-rundir.py" "$WTSH" "$FIX/run" "$FIX/manifests/valid-synthetic.json" "$REPO" "$TMPROOT" "$HEAD_NOW")

# --- 13b. run-directory mode re-derives the history; history that cannot be verified is never a pass ---
# Throwaway history: A (initial), B (changes Panel.tsx), E (empty commit on B), and S, a sibling of B:
# it also has parent A but carries A's tree, so B is not an ancestor of S and the B..S diff lists Panel.tsx.
REPOD="$TMPROOT/repo-drift"
make_repo "$REPOD" || fail "the history throwaway repository could not be created"
DRIFT_A=$(g "$REPOD" rev-parse HEAD)
printf 'one\ntwo\n' >"$REPOD/app/settings/Panel.tsx"
g "$REPOD" add -A && g "$REPOD" commit -q -m "change panel"
DRIFT_B=$(g "$REPOD" rev-parse HEAD)
g "$REPOD" commit -q --allow-empty -m "empty commit"
DRIFT_E=$(g "$REPOD" rev-parse HEAD)
DRIFT_S=$(g "$REPOD" commit-tree "$DRIFT_A^{tree}" -p "$DRIFT_A" -m "side commit")
check "the history repository has four distinct commits (control for the cases below)" "4" "$(printf '%s\n' "$DRIFT_A" "$DRIFT_B" "$DRIFT_E" "$DRIFT_S" | sort -u | wc -l | tr -d ' ')"
cat >"$TMPROOT/check-drift.py" <<'PY'
import importlib.util, os, sys
from wtlib import say, run, codes_of, build_run, head_at

here, wtsh, fixrun, fixm, repo, A, B, E, S = sys.argv[1:10]
BOGUS = "0123456789abcdef0123456789abcdef01234567"
synthetic = os.path.join(fixm, "valid-synthetic.json")
advanced = os.path.join(fixm, "valid-head-advanced.json")
empty_diff = os.path.join(fixm, "valid-head-advanced-empty-diff.json")
partial = os.path.join(fixm, "valid-partial-before-unavailable.json")
EQ = head_at(synthetic, "end")
FROM, TO = head_at(advanced, "start"), head_at(advanced, "end")
count = [0]


def case(label, base, shas, ok, texts=(), mutate=None, only_drift=True):
    """Place a fixture in the history repository in run-directory mode and check the verdict."""
    count[0] += 1
    run_dir = build_run(repo, fixrun, base, "wt-drift-%02d" % count[0], shas, mutate)
    proc = run(wtsh, ["validate", "--run-dir", run_dir])
    codes = codes_of(proc.stdout)
    if ok:
        say(proc.returncode == 0 and not codes, label, proc.stdout + proc.stderr)
        return
    good = proc.returncode == 1 and "WT-HEAD-DRIFT" in codes and all(t in proc.stdout for t in texts)
    if only_drift:
        good = good and codes == {"WT-HEAD-DRIFT"}
    say(good, label, "rc=%d codes=%s %s" % (proc.returncode, sorted(codes), proc.stdout))


case("control: equal heads that are the repository's real HEAD, with no committed changes, validate",
     synthetic, {EQ: A}, True)
case("equal heads that are not an available commit fail WT-HEAD-DRIFT only",
     synthetic, {EQ: BOGUS}, False, ["end.head", "not an available commit"])
case("control: two real commits with the exact endpoint diff validate",
     advanced, {FROM: A, TO: B}, True)
case("synthetic heads that do not exist in the repository fail WT-HEAD-DRIFT only (both heads named)",
     advanced, {}, False, ["start.head", "end.head", "not an available commit"])
proc = run(wtsh, ["validate", "--manifest", advanced, "--run-dir", fixrun])
say(proc.returncode == 0 and not codes_of(proc.stdout),
    "control: the same unmodified fixture validates in fixture mode (--manifest), which trusts committed_changes", proc.stdout + proc.stderr)
case("a start.head that is not in the repository fails WT-HEAD-DRIFT only",
     advanced, {FROM: BOGUS, TO: B}, False, ["start.head", "not an available commit"])
case("an end.head that is not in the repository fails WT-HEAD-DRIFT only",
     advanced, {FROM: A, TO: BOGUS}, False, ["end.head", "not an available commit"])
case("a start.head that is not an ancestor of end.head fails WT-HEAD-DRIFT only (the list itself is exact)",
     advanced, {FROM: B, TO: S}, False, ["not an ancestor"])
case("a wrong path in committed_changes fails WT-HEAD-DRIFT",
     advanced, {FROM: A, TO: B}, False, ["app/settings/Panel.tsx", "lib/format.ts", "endpoint diff"],
     mutate=lambda m: m["scope"]["committed_changes"][0].update(path="lib/format.ts"), only_drift=False)
case("a missing path in committed_changes fails WT-HEAD-DRIFT",
     advanced, {FROM: A, TO: B}, False, ["app/settings/Panel.tsx", "endpoint diff"],
     mutate=lambda m: m["scope"]["committed_changes"].clear(), only_drift=False)
case("a wrong change type in committed_changes fails WT-HEAD-DRIFT",
     advanced, {FROM: A, TO: B}, False, ["endpoint diff"],
     mutate=lambda m: m["scope"]["committed_changes"][0].update(change="added"), only_drift=False)
case("control: an empty commit has an empty endpoint diff, and an empty list validates",
     empty_diff, {FROM: B, TO: E}, True)
case("an empty list over a real endpoint diff fails WT-HEAD-DRIFT only",
     empty_diff, {FROM: A, TO: B}, False, ["app/settings/Panel.tsx", "endpoint diff"])
case("control: without a start snapshot, an end.head that is the repository's HEAD validates",
     partial, {EQ: A}, True)
case("without a start snapshot, an end.head that is not in the repository fails WT-HEAD-DRIFT only",
     partial, {}, False, ["end.head", "not an available commit"])

# git cannot say whether start.head is an ancestor (neither exit 0 nor 1): the rule fails, it never passes.
spec = importlib.util.spec_from_file_location("wt", os.path.join(here, "walkthrough.py"))
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
context = wt.Context()


def drift(ancestor, available=True, diff=()):
    wt.git_toplevel = lambda directory: directory
    wt.commit_available = lambda root, sha: available
    wt.is_ancestor = lambda root, older, newer: ancestor
    wt.committed_diff = lambda root, older, newer: list(diff)
    manifest = {"scope": {"start": {"head": "a" * 40}, "end": {"head": "b" * 40}, "committed_changes": []}}
    report = wt.Report()
    wt.ManifestChecker(manifest, context, os.path.join(repo, ".tmp"), True, report).rule_head_drift()
    return [item["message"] for item in report.failures]


say(drift(True) == [], "control: ancestry proven (exit 0) and an empty endpoint diff leave no failure")
unknown = drift(None)
say(len(unknown) == 1 and "could not tell" in unknown[0],
    "git failing to tell the ancestry (neither exit 0 nor 1) fails WT-HEAD-DRIFT instead of passing", unknown)
refused = drift(False)
say(len(refused) == 1 and "not an ancestor" in refused[0], "control: ancestry refused by git (exit 1) fails with the not-an-ancestor message", refused)
gone = drift(True, available=False)
say(len(gone) == 2 and all("not an available commit" in message for message in gone),
    "heads that are not available commits fail once each (start and end)", gone)
differs = drift(True, diff=[{"path": "x.txt", "change": "added"}])
say(len(differs) == 1 and "x.txt" in differs[0], "control: an endpoint diff that differs from the manifest list fails with the path named", differs)
print("DONE")
PY
apply_results "history proofs" < <(python3 -B "$TMPROOT/check-drift.py" "$HERE" "$WTSH" "$FIX/run" "$FIX/manifests" "$REPOD" "$DRIFT_A" "$DRIFT_B" "$DRIFT_E" "$DRIFT_S")

# --- 14. dispatcher, tunable parsing and the skill's invocation idiom ------------
run_wt -- bogus
check "an unknown subcommand is a usage error (exit 2)" "2" "$RUN_RC"
run_wt -- validate --run-dir "$FIX/run" --manifest "$FIX/manifests/valid-synthetic.json"
check "control: the dispatcher forwards arguments and the exit code" "0" "$RUN_RC"
MISSING_OUT=$(env PATH=/nonexistent /bin/bash "$WTSH" validate 2>&1)
MISSING_RC=$?
check "without python3 the dispatcher prints the requirement and exits 2" "2:ERROR: python3 is required" "$MISSING_RC:$MISSING_OUT"
EXPORT_PATTERN='^[[:space:]]*(export|declare -x|typeset -x)[[:space:]]'
check "the dispatcher exports nothing" "" "$(grep -nE "$EXPORT_PATTERN" "$WTSH")"
check "control: the export pattern does match a real export line" "1:export X=1" "$(printf 'export X=1\n' | grep -nE "$EXPORT_PATTERN")"
cat >"$TMPROOT/check-static.py" <<'PY'
import ast, importlib.util, os, re, sys

wt_path, skill_path = sys.argv[1], sys.argv[2]


def say(ok, text, detail=""):
    print("PASS\t" + text if ok else "FAIL\t%s\t%s" % (text, str(detail)[:300]))


def environment_writes(source):
    """Assignments to os.environ[...], os.putenv/unsetenv and os.environ mutators."""
    found = []
    for node in ast.walk(ast.parse(source)):
        targets = []
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, (ast.AugAssign, ast.AnnAssign)):
            targets = [node.target]
        elif isinstance(node, ast.Delete):
            targets = node.targets
        for target in targets:
            if isinstance(target, ast.Subscript) and ast.dump(target.value) == ast.dump(
                    ast.parse("os.environ").body[0].value):
                found.append(node.lineno)
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute):
            owner = ast.dump(node.func.value)
            if owner == ast.dump(ast.parse("os").body[0].value) and node.func.attr in ("putenv", "unsetenv"):
                found.append(node.lineno)
            if owner == ast.dump(ast.parse("os.environ").body[0].value) and node.func.attr in (
                    "update", "setdefault", "pop", "popitem", "clear"):
                found.append(node.lineno)
    return found


say(environment_writes(open(wt_path).read()) == [], "the helper never writes the process environment (no export, no derivation)")
say(environment_writes('import os\nos.environ["X"] = "1"\n') == [2] and environment_writes('import os\nos.putenv("A", "b")\n') == [2]
    and environment_writes('import os\nos.environ.setdefault("A", "b")\n') == [2],
    "control: the environment-write scan does flag a subscript assignment, putenv and setdefault")

# Provider-neutral: Claude skills expand ${CLAUDE_PLUGIN_ROOT}; Codex skills
# substitute the literal installed root for <PLUGIN_ROOT>.
idioms = ('bash "${CLAUDE_PLUGIN_ROOT}/scripts/walkthrough.sh"', 'bash "<PLUGIN_ROOT>/scripts/walkthrough.sh"')


def idiom_problems(text):
    problems = []
    helpers = text.split("## Helpers", 1)[1].split("\n## ", 1)[0] if "## Helpers" in text else ""
    if not helpers:
        return ["no Helpers section"]
    fences = re.findall(r"```[a-z]*\n(.*?)```", helpers, re.S)
    if not fences:
        problems.append("no fenced invocation block in Helpers")
    for block in fences:
        for line in [x for x in block.splitlines() if x.strip()]:
            if not any(line.startswith(idiom) for idiom in idioms):
                problems.append("invocation line does not start with the literal idiom: %r" % line)
            for banned in ("&&", "||", " | ", ";", "$(", "`", ">>", " > ", " 2>"):
                if banned in line:
                    problems.append("invocation line chains or redirects (%r): %r" % (banned, line))
    for sub in ("validate", "render", "scope"):
        if not re.search(r"^\|\s*`%s`" % sub, helpers, re.M):
            problems.append("Helpers table has no row for %s" % sub)
    return problems


say(idiom_problems(open(skill_path, encoding="utf-8").read()) == [],
    "SKILL.md documents each subcommand with the one-literal-segment invocation", idiom_problems(open(skill_path, encoding="utf-8").read()))
bad_text = "## Helpers\n```bash\nexport X=1 && " + idioms[0] + " validate\n```\n| `validate` | x |\n"
say(len(idiom_problems(bad_text)) >= 2, "control: the idiom check does flag a prefixed, chained invocation and missing rows")

spec = importlib.util.spec_from_file_location("wt", wt_path)
wt = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wt)
bad = []
for raw, want in (("abc", 10), ("", 10), ("-1", 10), ("1.5", 10), ("0", 0), ("7", 7), ("007", 7)):
    os.environ["WT_TEST_LOCK"] = raw
    got = wt.env_int("WT_TEST_LOCK", 10, 0)
    if got != want:
        bad.append((raw, got, want))
os.environ["WT_TEST_BYTES"] = "0"
if wt.env_int("WT_TEST_BYTES", 8388608, 1) != 8388608:
    bad.append(("bytes 0", "not default"))
del os.environ["WT_TEST_BYTES"]
if wt.env_int("WT_TEST_BYTES", 8388608, 1) != 8388608:
    bad.append(("unset", "not default"))
say(not bad, "tunable parsing falls back to the default for non-numeric, negative, fractional, empty and below-minimum values", bad)
print("DONE")
PY
apply_results "static checks" < <(python3 -B "$TMPROOT/check-static.py" "$HERE/walkthrough.py" "$PLUGIN/skills/session-walkthrough/SKILL.md")


printf 'session-walkthrough tests: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
