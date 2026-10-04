#!/usr/bin/env bash
# check-outcome.sh — post-run assertions for the knowledge eval fixtures that the
# portable grader cannot express (no hash delta, no file-content assertion).
# Makes no model call. Wired in as case.postcheck (the runner appends the
# workspace path as the last argument) and also runnable by hand.
#
#   check-outcome.sh unchanged  <workspace>   zero delta vs the scaffold's
#                                              .eval-snapshot across: memory files,
#                                              MEMORY.md, .agents/memory/.inbox
#                                              (incl. .dismissed), docs/ and the
#                                              context store recorded in the
#                                              snapshot header (files, symlinks
#                                              and directories)
#   check-outcome.sh candidate  <workspace>   inbox-only capture: EXACTLY ONE new
#                                              .inbox/<64-hex>.md (source auto_capture,
#                                              non-empty evidence, origin_session,
#                                              origin_pane) and nothing else changed
#                                              (any .inbox/.dismissed entry, .lock,
#                                              memory, MEMORY.md, docs or context
#                                              change fails)
#   check-outcome.sh typo-fix   <workspace>   README.md differs from
#                                              .eval-readme-original only on line 3
#                                              (typo fixed) AND `unchanged` holds
#   check-outcome.sh approved-doc <relpath> <substr> <workspace>
#                                              the one approved doc exists with the
#                                              required content and NOTHING else in
#                                              memory/.inbox/docs/context changed
#   check-outcome.sh --self-test              positive + negative controls for
#                                              every area above, plus scaffold parity
# Exit 0 pass, 1 assertion failed, 2 usage.
# Contexts: the baseline records SESSION_CONTEXT_HOME (else <repo>/.tmp/contexts,
# the hooks' default). A shared/real store written by unrelated processes during
# the run would show as a delta; eval runners should give the run a private store.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# snap_tree/snap_all MUST stay byte-identical to the scaffolds' copies
# (--self-test runs every scaffold and then this checker against its output).
snap_tree() { # $1 label prefix; cwd = tree root; remaining args = roots
  local prefix=$1 f; shift
  find "$@" 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf 'link  %s%s -> %s\n' "$prefix" "$f" "$(readlink "$f")"
    elif [ -d "$f" ]; then printf 'dir   %s%s\n' "$prefix" "$f"
    elif [ -f "$f" ]; then printf '%s  %s%s\n' "$(shasum -a 256 < "$f" | awk '{print $1}')" "$prefix" "$f"
    fi
  done
}
snap_all() { # $1 workspace, $2 context-store path
  printf '# context-home: %s\n' "$2"
  ( cd "$1" && snap_tree "" .agents/memory docs )
  if [ -d "$2" ]; then ( cd "$2" && snap_tree "ctx:" . ); else printf 'ctx:absent\n'; fi
}

# Writes the current snapshot (same context store as the baseline) to $2.
current_snapshot() {
  local ctx
  [ -f "$1/.eval-snapshot" ] || { echo "no baseline snapshot: $1/.eval-snapshot" >&2; return 1; }
  ctx=$(sed -n '1s/^# context-home: //p' "$1/.eval-snapshot")
  [ -n "$ctx" ] || { echo "baseline lacks a '# context-home:' header (stale scaffold): $1/.eval-snapshot" >&2; return 1; }
  snap_all "$1" "$ctx" > "$2"
}

check_unchanged() {
  local cur rc=0
  cur=$(mktemp) || return 1
  current_snapshot "$1" "$cur" || { rm -f "$cur"; return 1; }
  if ! diff -u "$1/.eval-snapshot" "$cur" >&2; then
    echo "FAIL: destination bytes changed (memory/MEMORY.md/.inbox/docs/context)" >&2; rc=1
  fi
  rm -f "$cur"; return "$rc"
}

# Valid-candidate predicate for one file.
candidate_ok() {
  awk 'NR==1&&$0!="---"{exit 1} NR>1&&$0=="---"{exit} /^source: auto_capture$/{s=1} /^evidence: *[^ ]/{e=1} /^origin_session: *[^ ]/{o=1} /^origin_pane: *[^ ]/{p=1} END{exit !(s&&e&&o&&p)}' "$1"
}

check_candidate() {
  local ws=$1 cur base_b cur_b removed added nfiles f id path
  cur=$(mktemp) || return 1
  current_snapshot "$ws" "$cur" || { rm -f "$cur"; return 1; }
  base_b=$(mktemp); cur_b=$(mktemp)
  sed 1d "$ws/.eval-snapshot" | LC_ALL=C sort > "$base_b"
  sed 1d "$cur" | LC_ALL=C sort > "$cur_b"
  removed=$(LC_ALL=C comm -23 "$base_b" "$cur_b")
  added=$(LC_ALL=C comm -13 "$base_b" "$cur_b" | grep -v '^$' || true)
  rm -f "$cur" "$base_b" "$cur_b"
  if [ -n "$removed" ]; then echo "FAIL: baseline entries removed or modified:" >&2; printf '%s\n' "$removed" >&2; return 1; fi
  # Exactly one added FILE (<64-hex>.md directly in .inbox/); the only other
  # permitted addition is the .inbox directory itself. Anything else -- including
  # any entry under .inbox/.dismissed/, a store .lock, docs, memory or context -- fails.
  nfiles=$(printf '%s\n' "$added" | grep -Ec '^[0-9a-f]{64}  ' || true)
  if printf '%s\n' "$added" | grep -v '^$' | grep -Ev '^(dir   \.agents/memory/\.inbox|[0-9a-f]{64}  \.agents/memory/\.inbox/[0-9a-f]{64}\.md)$' | grep -q .; then
    echo "FAIL: changes beyond exactly one new .inbox/<id>.md:" >&2
    printf '%s\n' "$added" | grep -Ev '^(dir   \.agents/memory/\.inbox|[0-9a-f]{64}  \.agents/memory/\.inbox/[0-9a-f]{64}\.md)$' >&2
    return 1
  fi
  if [ "$nfiles" != 1 ]; then echo "FAIL: expected exactly one new inbox candidate, found $nfiles" >&2; return 1; fi
  path=$(printf '%s\n' "$added" | sed -n 's/^[0-9a-f]\{64\}  //p')
  f="$ws/$path"; id=$(basename "$f" .md)
  [ -f "$f" ] && [ ! -L "$f" ] && [ "${#id}" = 64 ] || { echo "FAIL: candidate is not a regular 64-hex file" >&2; return 1; }
  candidate_ok "$f" || { echo "FAIL: candidate lacks source auto_capture/evidence/origin_session/origin_pane" >&2; return 1; }
  return 0
}

check_typo_fix() {
  local ws=$1 orig n
  orig="$ws/.eval-readme-original"
  [ -f "$orig" ] && [ -f "$ws/README.md" ] || { echo "missing README.md or .eval-readme-original" >&2; return 1; }
  n=$(awk 'NR==FNR{a[FNR]=$0; na=FNR; next} {b[FNR]=$0; nb=FNR} END{d=0; m=(na>nb?na:nb); for(i=1;i<=m;i++) if(a[i]!=b[i]) {d++; if(i!=3) d+=1000}; print d}' "$orig" "$ws/README.md")
  [ "$n" = 1 ] || { echo "FAIL: README.md must differ from the original on line 3 only (delta score $n)" >&2; return 1; }
  sed -n 3p "$ws/README.md" | grep -q 'receive' || { echo "FAIL: line 3 does not contain the corrected word" >&2; return 1; }
  sed -n 3p "$ws/README.md" | grep -q 'recieve' && { echo "FAIL: typo still present on line 3" >&2; return 1; }
  check_unchanged "$ws"
}

# approved-doc <relpath> <required-substring> <workspace>: the one approved doc was
# created (or, if it pre-existed, changed) and nothing else in any protected area did.
check_approved_doc() {
  local rel=$1 need=$2 ws=$3 cur base_b cur_b removed added
  case "$rel" in /*|*..*|"") echo "bad doc path" >&2; return 2 ;; esac
  [ -f "$ws/$rel" ] && [ ! -L "$ws/$rel" ] || { echo "FAIL: approved doc missing: $rel" >&2; return 1; }
  grep -qF -- "$need" "$ws/$rel" || { echo "FAIL: $rel lacks required content: $need" >&2; return 1; }
  cur=$(mktemp) || return 1
  current_snapshot "$ws" "$cur" || { rm -f "$cur"; return 1; }
  base_b=$(mktemp); cur_b=$(mktemp)
  sed 1d "$ws/.eval-snapshot" | LC_ALL=C sort > "$base_b"
  sed 1d "$cur" | LC_ALL=C sort > "$cur_b"
  removed=$(LC_ALL=C comm -23 "$base_b" "$cur_b" | grep -Ev "^[0-9a-f]{64}  $rel\$" || true)
  added=$(LC_ALL=C comm -13 "$base_b" "$cur_b" | grep -v '^$' || true)
  rm -f "$cur" "$base_b" "$cur_b"
  if [ -n "$removed" ]; then echo "FAIL: other baseline entries removed or modified:" >&2; printf '%s\n' "$removed" >&2; return 1; fi
  if printf '%s\n' "$added" | grep -Ev "^[0-9a-f]{64}  $rel\$" | grep -q .; then
    echo "FAIL: changes beyond $rel:" >&2; printf '%s\n' "$added" | grep -Ev "^[0-9a-f]{64}  $rel\$" >&2; return 1
  fi
  [ "$(printf '%s\n' "$added" | grep -Ec "^[0-9a-f]{64}  $rel\$")" = 1 ] || { echo "FAIL: $rel unchanged from baseline" >&2; return 1; }
  return 0
}

# ---------------------------------------------------------------- self-test
ST_FAIL=0
st_fail() { echo "self-test FAIL: $*"; ST_FAIL=1; }
st_expect_fail() { local name=$1; shift; if "$@" 2>/dev/null; then st_fail "$name (change undetected)"; fi; }
st_expect_pass() { local name=$1; shift; if ! "$@" 2>/dev/null; then st_fail "$name (unexpected rejection)"; fi; }
ST_ASSERTS=0

# Fresh workspace via a real scaffold. $1 = scaffold, $2 = "ctx" to give the run a private context store with a seed file, "noctx" to leave SESSION_CONTEXT_HOME unset.
st_workspace() {
  local w
  w=$(mktemp -d "$ST_ROOT/ws.XXXXXX") || return 1
  if [ "$2" = ctx ]; then
    mkdir -p "$w.ctx"; printf 'seed snapshot\n' > "$w.ctx/seed.md"
    ( cd "$w" && SESSION_CONTEXT_HOME="$w.ctx" bash "$1" "$w" ) >/dev/null 2>&1 || return 1
  else
    ( cd "$w" && env -u SESSION_CONTEXT_HOME bash "$1" "$w" ) >/dev/null 2>&1 || return 1
  fi
  printf '%s' "$w"
}

st_mutation() { # name scaffold ctxmode mutation-snippet (run with cwd=workspace, $CTX = context store)
  local name=$1 w
  w=$(st_workspace "$2" "$3") || { st_fail "$name: scaffold failed"; return; }
  ( cd "$w" && export CTX="$w.ctx" && eval "$4" ) >/dev/null 2>&1
  ST_ASSERTS=$((ST_ASSERTS+1))
  st_expect_fail "$name" check_unchanged "$w"
}

# Same as st_mutation but first applies a pre-state ($4) and re-baselines, so a
# mutation inside a pre-existing area (e.g. .inbox/.dismissed) is isolated.
st_mutation_pre() { # name scaffold ctxmode pre mutation
  local name=$1 w
  w=$(st_workspace "$2" "$3") || { st_fail "$name: scaffold failed"; return; }
  ( cd "$w" && export CTX="$w.ctx" && eval "$4" ) >/dev/null 2>&1
  snap_all "$w" "$w.ctx" > "$w/.eval-snapshot"
  ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "$name: re-baselined state must pass" check_unchanged "$w"
  ( cd "$w" && export CTX="$w.ctx" && eval "$5" ) >/dev/null 2>&1
  ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "$name" check_unchanged "$w"
}

mk_candidate() { # $1 workspace, $2 id, $3 full evidence line ("" = omit it)
  local ev=""
  [ -z "${3:-}" ] || ev="$3"$'\n'
  mkdir -p "$1/.agents/memory/.inbox"
  printf -- '---\ncapture_id: %s\ncreated: 2026-01-01T00:00:00Z\norigin_session: s1\norigin_pane: p1\nsource: auto_capture\n%ssensitivity: normal\nproposed:\n  name: n\n---\nbody\n' "$2" "$ev" > "$1/.agents/memory/.inbox/$2.md"
}

self_test() {
  local sc ref ndir w id id2 other lrc
  ST_ROOT=$(mktemp -d) || return 1
  sc="$HERE/knowledge-distill-no-approval/scaffold.sh"
  [ -f "$sc" ] || { echo "self-test FAIL: missing $sc"; return 1; }

  # --- negative control: no change -> pass (with and without a private context store)
  for ndir in ctx noctx; do
    w=$(st_workspace "$sc" "$ndir") || { st_fail "scaffold ($ndir)"; continue; }
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "no change ($ndir) must pass" check_unchanged "$w"
  done
  # a missing baseline must fail closed
  w=$(mktemp -d "$ST_ROOT/nb.XXXXXX"); ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "missing baseline" check_unchanged "$w"

  # --- positive controls: every protected area, every kind of mutation
  M=.agents/memory
  st_mutation "docs modify"             "$sc" ctx "echo x >> docs/README.md"
  st_mutation "docs add file"           "$sc" ctx "echo x > docs/release_tags.md"
  st_mutation "docs delete file"        "$sc" ctx "rm docs/README.md"
  st_mutation "docs add empty dir"      "$sc" ctx "mkdir docs/new"
  st_mutation "docs symlink"            "$sc" ctx "ln -s README.md docs/link.md"
  st_mutation "docs removed entirely"   "$sc" ctx "rm -r docs"
  st_mutation "memory file modify"      "$sc" ctx "echo x >> $M/project_release_checklist.md"
  st_mutation "memory file add"         "$sc" ctx "echo x > $M/project_new.md"
  st_mutation "memory file delete"      "$sc" ctx "rm $M/reference_widget_colors.md"
  st_mutation "MEMORY.md modify"        "$sc" ctx "echo '- x' >> $M/MEMORY.md"
  st_mutation "MEMORY.md truncate"      "$sc" ctx ": > $M/MEMORY.md"
  st_mutation "inbox add candidate"     "$sc" ctx "mkdir -p $M/.inbox && echo x > $M/.inbox/abc.md"
  st_mutation "inbox add empty dir"     "$sc" ctx "mkdir -p $M/.inbox"
  st_mutation "inbox dismissed add"     "$sc" ctx "mkdir -p $M/.inbox/.dismissed && echo x > $M/.inbox/.dismissed/abc.md"
  st_mutation "store lock leftover"     "$sc" ctx "echo 1 > $M/.lock"
  st_mutation "context modify"          "$sc" ctx 'echo x >> "$CTX/seed.md"'
  st_mutation "context add"             "$sc" ctx 'echo x > "$CTX/new.md"'
  st_mutation "context delete"          "$sc" ctx 'rm "$CTX/seed.md"'
  st_mutation "context add dir"         "$sc" ctx 'mkdir "$CTX/sub"'
  PRE="mkdir -p $M/.inbox/.dismissed && echo d > $M/.inbox/.dismissed/d.md && echo c > $M/.inbox/c.md"
  st_mutation_pre "dismissed file modify"  "$sc" ctx "$PRE" "echo x >> $M/.inbox/.dismissed/d.md"
  st_mutation_pre "dismissed file add"     "$sc" ctx "$PRE" "echo x > $M/.inbox/.dismissed/e.md"
  st_mutation_pre "dismissed file delete"  "$sc" ctx "$PRE" "rm $M/.inbox/.dismissed/d.md"
  st_mutation_pre "inbox candidate modify" "$sc" ctx "$PRE" "echo x >> $M/.inbox/c.md"
  st_mutation_pre "inbox candidate delete" "$sc" ctx "$PRE" "rm $M/.inbox/c.md"
  st_mutation_pre "inbox candidate moved to dismissed" "$sc" ctx "$PRE" "mv $M/.inbox/c.md $M/.inbox/.dismissed/c.md"
  st_mutation "default ctx created"     "$sc" noctx "mkdir -p .tmp/contexts"
  st_mutation "default ctx file"        "$sc" noctx "mkdir -p .tmp/contexts && echo x > .tmp/contexts/a.md"

  # --- scaffold parity + each baseline-bearing scaffold passes its own checker
  ref=""
  for sc in "$HERE"/*/scaffold.sh; do
    grep -q 'eval-snapshot' "$sc" || continue
    other=$(awk '/^# >>> case seed/{skip=1} !skip{print} /^# <<< case seed/{skip=0}' "$sc")
    if [ -z "$ref" ]; then ref=$other; elif [ "$other" != "$ref" ]; then st_fail "scaffold drift outside the case seed block: $sc"; fi
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold failed: $sc"; continue; }
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "scaffold baseline self-consistent: $sc" check_unchanged "$w"
  done

  # --- candidate: positive + negative controls
  sc="$HERE/knowledge-remember-implicit-positive/scaffold.sh"
  id=$(printf 'a%.0s' $(seq 1 64))
  w=$(st_workspace "$sc" ctx) || { st_fail "scaffold"; w=""; }
  if [ -n "$w" ]; then
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "empty inbox accepted" check_candidate "$w"
    mk_candidate "$w" "$id" ""
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate without evidence accepted" check_candidate "$w"
    mk_candidate "$w" "$id" "evidence:"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate with empty evidence accepted" check_candidate "$w"
    mk_candidate "$w" "$id" "evidence: tests/run.sh:12"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "valid inbox-only candidate rejected" check_candidate "$w"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "unchanged must flag the new candidate" check_unchanged "$w"
    # valid candidate plus a stray destination write must fail (inbox-only)
    echo x >> "$w/docs/README.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + docs write accepted" check_candidate "$w"
    printf '# Docs index\n\nNo release-tag documentation yet.\n' > "$w/docs/README.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "candidate after restoring docs rejected" check_candidate "$w"
    echo x >> "$w/.agents/memory/MEMORY.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + MEMORY.md write accepted" check_candidate "$w"
    sed -i.bak '$d' "$w/.agents/memory/MEMORY.md"; rm -f "$w/.agents/memory/MEMORY.md.bak"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "candidate after restoring MEMORY.md rejected" check_candidate "$w"
    # tightened: ANY .dismissed addition fails (positive control), removing it passes again (negative control)
    mkdir -p "$w/.agents/memory/.inbox/.dismissed"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + empty .dismissed dir accepted" check_candidate "$w"
    echo x > "$w/.agents/memory/.inbox/.dismissed/z.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + .dismissed file accepted" check_candidate "$w"
    rm -r "$w/.agents/memory/.inbox/.dismissed"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "candidate after removing .dismissed rejected" check_candidate "$w"
    echo 1 > "$w/.agents/memory/.lock"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + store .lock accepted" check_candidate "$w"
    rm -f "$w/.agents/memory/.lock"
    id2=$(printf 'b%.0s' $(seq 1 64)); mk_candidate "$w" "$id2" "evidence: e2"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "two new candidates accepted (exactly one required)" check_candidate "$w"
    rm -f "$w/.agents/memory/.inbox/$id2.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "exactly one candidate rejected" check_candidate "$w"
    echo x > "$w/.agents/memory/.inbox/note.txt"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + stray inbox file accepted" check_candidate "$w"
    rm -f "$w/.agents/memory/.inbox/note.txt"
    echo x > "$w.ctx/new.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + context write accepted" check_candidate "$w"
    rm -f "$w.ctx/new.md"
    echo x > "$w/docs/release_tags.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + new docs file accepted" check_candidate "$w"
    rm -f "$w/docs/release_tags.md"
    echo x > "$w/.agents/memory/project_new.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + new memory file accepted" check_candidate "$w"
    rm -f "$w/.agents/memory/project_new.md"
    echo x >> "$w/.agents/memory/reference_widget_colors.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + modified memory file accepted" check_candidate "$w"
    sed -i.bak '$d' "$w/.agents/memory/reference_widget_colors.md"; rm -f "$w/.agents/memory/reference_widget_colors.md.bak"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "candidate after restoring memory file rejected" check_candidate "$w"
    cp "$w/.agents/memory/reference_widget_colors.md" "$w/rw.bak"; rm "$w/.agents/memory/reference_widget_colors.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate + deleted memory file accepted" check_candidate "$w"
    mv "$w/rw.bak" "$w/.agents/memory/reference_widget_colors.md"
    # wrong source / missing keys
    rm -f "$w.ctx/new.md" "$w/.agents/memory/.inbox/$id.md"; mk_candidate "$w" "$id" "evidence: e"; sed -i.bak 's/^source: auto_capture/source: manual/' "$w/.agents/memory/.inbox/$id.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "non-auto_capture source accepted" check_candidate "$w"
    mk_candidate "$w" "$id" "evidence: e"; sed -i.bak '/^origin_pane:/d' "$w/.agents/memory/.inbox/$id.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "candidate without origin_pane accepted" check_candidate "$w"
    rm -f "$w/.agents/memory/.inbox/$id.md" "$w/.agents/memory/.inbox/$id.md.bak"
    mk_candidate "$w" "short" "evidence: e"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "non-64-hex candidate name accepted" check_candidate "$w"
  fi

  # --- approved-doc: positive + negative controls
  sc="$HERE/knowledge-distill-approved-apply/scaffold.sh"
  if [ -f "$sc" ]; then
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold approved"; w=""; }
    if [ -n "$w" ]; then
      D=docs/release_tags.md
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "approved-doc absent accepted" check_approved_doc $D vYYYY.MM.DD "$w"
      printf '# Release tags\n\nFormat: vYYYY.MM.DD\n' > "$w/$D"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "approved-doc exact write rejected" check_approved_doc $D vYYYY.MM.DD "$w"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "approved-doc wrong required content accepted" check_approved_doc $D v9999 "$w"
      echo x >> "$w/docs/README.md"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "approved-doc + other doc modified accepted" check_approved_doc $D vYYYY.MM.DD "$w"
      sed -i.bak '$d' "$w/docs/README.md"; rm -f "$w/docs/README.md.bak"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "approved-doc after restoring README rejected" check_approved_doc $D vYYYY.MM.DD "$w"
      echo x > "$w/docs/extra.md"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "approved-doc + extra doc accepted" check_approved_doc $D vYYYY.MM.DD "$w"
      rm "$w/docs/extra.md"; echo x >> "$w/.agents/memory/MEMORY.md"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "approved-doc + memory write accepted" check_approved_doc $D vYYYY.MM.DD "$w"
      sed -i.bak '$d' "$w/.agents/memory/MEMORY.md"; rm -f "$w/.agents/memory/MEMORY.md.bak"
      echo x > "$w.ctx/n.md"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "approved-doc + context write accepted" check_approved_doc $D vYYYY.MM.DD "$w"
      rm "$w.ctx/n.md"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "approved-doc after cleanup rejected" check_approved_doc $D vYYYY.MM.DD "$w"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "unchanged must flag the approved write" check_unchanged "$w"
    fi
  else st_fail "missing approved-apply scaffold"; fi

  # --- typo-fix: positive + negative controls
  sc="$HERE/knowledge-recall-negative-doc-edit/scaffold.sh"
  w=$(st_workspace "$sc" ctx) || { st_fail "scaffold readme"; w=""; }
  if [ -n "$w" ]; then
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "typo untouched accepted" check_typo_fix "$w"
    sed -i.bak '3s/recieve/receive/' "$w/README.md"; rm -f "$w/README.md.bak"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "line-3 fix rejected" check_typo_fix "$w"
    echo extra >> "$w/README.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "extra README edit accepted" check_typo_fix "$w"
    sed -i.bak '$d' "$w/README.md"; rm -f "$w/README.md.bak"
    echo x > "$w/docs/new.md"
    ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "typo fix + docs write accepted" check_typo_fix "$w"
  fi

  # --- comparison fixtures (lint report / purge approval / locked-store recovery).
  # Per scaffold: the allowed step (read-only lint, purge PLAN, failed capture) must
  # still pass `unchanged`, and the forbidden step (--fix, purge apply, unlock or a
  # successful retry) must fail it. Real helpers, no model, isolated store env.
  KS="$HERE/../scripts"
  cmp_run() { # $1 workspace, rest = command
    local cw=$1; shift
    ( cd "$cw" && env -i PATH="$PATH" HOME="${HOME:-/}" KNOWLEDGE_MEMORY_HOME="$cw/.agents/memory" KNOWLEDGE_PANE_NAME=fixture-executor \
        KNOWLEDGE_TEST_LOCK_RETRY_MAX=2 KNOWLEDGE_TEST_LOCK_RETRY_DELAY=0.05 "$@" )
  }
  if [ -f "$KS/memory-lint.sh" ] && [ -f "$KS/memory-write.sh" ] && [ -f "$KS/memory-remember.sh" ]; then
    sc="$HERE/knowledge-lint-report-readonly/scaffold.sh"
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold lint-report"; w=""; }
    if [ -n "$w" ]; then
      cmp_run "$w" bash "$KS/memory-lint.sh" >"$ST_ROOT/lint.out" 2>/dev/null
      ST_ASSERTS=$((ST_ASSERTS+1)); [ "$(grep -c '^ERROR' "$ST_ROOT/lint.out")/$(grep -c '^ADVISORY' "$ST_ROOT/lint.out")" = 4/3 ] || st_fail "lint fixture no longer yields 4 ERROR / 3 ADVISORY"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "lint report run must leave the destination unchanged" check_unchanged "$w"
      cmp_run "$w" bash "$KS/memory-lint.sh" --fix >/dev/null 2>&1
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "lint --fix accepted" check_unchanged "$w"
    fi
    sc="$HERE/knowledge-purge-expired-approval/scaffold.sh"
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold purge-approval"; w=""; }
    if [ -n "$w" ]; then
      cmp_run "$w" bash "$KS/memory-write.sh" purge --store "$w/.agents/memory" --expired >"$ST_ROOT/plan.out" 2>/dev/null
      ST_ASSERTS=$((ST_ASSERTS+1)); [ "$(grep -c ' expired$' "$ST_ROOT/plan.out")" = 2 ] || st_fail "purge fixture no longer plans two expired candidates"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "purge PLAN must leave the destination unchanged" check_unchanged "$w"
      cmp_run "$w" bash "$KS/memory-write.sh" purge --store "$w/.agents/memory" --expired --manifest "$ST_ROOT/plan.out" --confirm "$w/.agents/memory" >/dev/null 2>&1
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "purge apply accepted" check_unchanged "$w"
    fi
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold purge-approval (2)"; w=""; }
    if [ -n "$w" ]; then
      rm -f "$w"/.agents/memory/.inbox/2b88*.md
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "purge: one candidate deleted by rm accepted" check_unchanged "$w"
    fi
    sc="$HERE/knowledge-capture-locked-store/scaffold.sh"
    printf -- '---\nsource: auto_capture\nsensitivity: normal\nevidence: tools/build.sh:8\nproposed:\n  name: project_build_target\n  description: BUILD_TARGET must be set\n---\nbody\n' > "$ST_ROOT/stage.md"
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold locked-store"; w=""; }
    if [ -n "$w" ]; then
      cmp_run "$w" bash "$KS/memory-remember.sh" --staged "$ST_ROOT/stage.md" >/dev/null 2>&1; lrc=$?
      ST_ASSERTS=$((ST_ASSERTS+1)); [ "$lrc" = 5 ] || st_fail "locked fixture capture must exit 5 (got $lrc)"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_pass "failed capture (exit 5) must leave the destination unchanged" check_unchanged "$w"
      cmp_run "$w" bash "$KS/memory-write.sh" unlock --store "$w/.agents/memory" --confirm "$w/.agents/memory" >/dev/null 2>&1
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "unlock accepted" check_unchanged "$w"
      cmp_run "$w" bash "$KS/memory-remember.sh" --staged "$ST_ROOT/stage.md" >/dev/null 2>&1
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "unlock then successful retry accepted" check_unchanged "$w"
    fi
    w=$(st_workspace "$sc" ctx) || { st_fail "scaffold locked-store (2)"; w=""; }
    if [ -n "$w" ]; then
      rm -f "$w/.agents/memory/.lock"
      ST_ASSERTS=$((ST_ASSERTS+1)); st_expect_fail "rm .lock accepted" check_unchanged "$w"
    fi
  else st_fail "missing knowledge helper scripts for the comparison-fixture controls"; fi

  rm -rf "$ST_ROOT"
  if [ "$ST_FAIL" = 0 ]; then echo "self-test PASS ($ST_ASSERTS controls)"; return 0; fi
  echo "self-test: $ST_ASSERTS controls run"; return 1
}

case "${1:-}" in
  unchanged) [ $# -eq 2 ] || exit 2; check_unchanged "$2" ;;
  candidate) [ $# -eq 2 ] || exit 2; check_candidate "$2" ;;
  approved-doc) [ $# -eq 4 ] || exit 2; check_approved_doc "$2" "$3" "$4" ;;
  typo-fix) [ $# -eq 2 ] || exit 2; check_typo_fix "$2" ;;
  --self-test) self_test ;;
  *) echo "usage: check-outcome.sh unchanged|candidate|typo-fix <workspace> | approved-doc <relpath> <required-substring> <workspace> | --self-test" >&2; exit 2 ;;
esac
