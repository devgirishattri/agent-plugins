#!/usr/bin/env bash
# test-diagnostics.sh — Tier 1.3a: diag/1 diagnostics for the ORDINARY paths of
# task-done.sh, task-block.sh and task-review.sh (and the bounded fixes that
# ship with them). Every trigger test is paired with a valid-path control.
#
# Environment (all optional):
#   DIAG_SCHED_DIR     scripts directory under test (default: this directory).
#                      Point it at a release archive to prove the tests FAIL there.
#   DIAG_REGISTRY      registry.json to check (default: ../diagnostics/registry.json).
#   DIAG_BASH          bash used to run the helpers (default: bash on PATH; try /bin/bash 3.2).
#   DIAG_BASELINE_DIR  scripts directory of the released baseline. When set, the
#                      behavioural baseline comparison also runs.
#   DIAG_KEEP_DIR      when set, raw and normalised baseline transcripts are copied there.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPTS="${DIAG_SCHED_DIR:-$HERE}"
REGISTRY="${DIAG_REGISTRY:-$HERE/../diagnostics/registry.json}"
BASELINE="${DIAG_BASELINE_DIR:-}"
CHAT_SRC="$HERE/../../session-chat/scripts"
BASH_BIN="${DIAG_BASH:-$(command -v bash)}"
ROOT=$(mktemp -d "${TMPDIR:-/tmp}/dg13.XXXXXX") || exit 1
ROOT=$(cd "$ROOT" && pwd -P)
HOLD_PID=""

PASS=0; FAIL=0; FAILURES=()
pass() { PASS=$((PASS+1)); echo "  PASS  $1"; }
fail() { FAIL=$((FAIL+1)); FAILURES+=("$1: $2"); echo "  FAIL  $1 — $2"; }
cleanup() { [ -n "$HOLD_PID" ] && kill "$HOLD_PID" 2>/dev/null; rm -rf "$ROOT"; }
trap cleanup EXIT

bad=""
finish() { # finish <test-name>
  if [ -z "$bad" ]; then pass "$1"; else fail "$1" "$bad"; fi
  bad=""
}
ck() { # ck <label> <command...>: record a failed check
  local label="$1"; shift
  "$@" >/dev/null 2>&1 || bad="$bad [$label]"
}
ckx() { # ckx <label> '<shell expression>' (may contain pipes)
  eval "$2" >/dev/null 2>&1 || bad="$bad [$1]"
}

# A long-lived process whose pid stands in for a live lock holder.
sleep 600 & HOLD_PID=$!

# ---------------------------------------------------------------- shims -----
# One PATH directory of controllable shims; every shim is inert unless its DG_*
# switch is set, so the SAME PATH serves the fault run and its control run.
SHIM="$ROOT/shim"; mkdir -p "$SHIM"
REAL_MKTEMP=$(command -v mktemp); REAL_MV=$(command -v mv); REAL_JQ=$(command -v jq)
REAL_OD=$(command -v od); REAL_MKDIR=$(command -v mkdir); REAL_GREP=$(command -v grep)
cat > "$SHIM/mktemp" <<EOF
#!/usr/bin/env bash
if [ "\${DG_MKTEMP_FAIL_RELEASE:-}" = 1 ]; then case "\$*" in *.release.*) exit 1 ;; esac; fi
exec "$REAL_MKTEMP" "\$@"
EOF
cat > "$SHIM/mv" <<EOF
#!/usr/bin/env bash
# Ledger commits are mv of *.json.tmp.*; every switch counts them (DG_LOG/mvcount).
#   DG_MV_FAIL=<n|all>     fail the n-th commit BEFORE any rename (staged file stays).
#   DG_MV_KILL=<n>         perform the real rename of the n-th commit, record it in
#                          DG_LOG/killed.log, then SIGKILL this wrapper: the caller sees a
#                          failed mv although the publication happened.
#   DG_MV_AFTER=<action>:<n>  after the n-th commit succeeds, tamper with the verdict
#                          artifact (tamper) or pre-create its notice file (notice).
case "\$1" in
  *.json.tmp.*)
    if [ -n "\${DG_MV_FAIL:-}\${DG_MV_KILL:-}\${DG_MV_AFTER:-}" ]; then
      n=\$(cat "\$DG_LOG/mvcount" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$DG_LOG/mvcount"
      if [ "\${DG_MV_FAIL:-}" = all ] || [ "\${DG_MV_FAIL:-}" = "\$n" ]; then exit 1; fi
      if [ "\${DG_MV_KILL:-}" = "\$n" ]; then
        "$REAL_MV" "\$@" || exit \$?
        echo "published:\$n" >> "\$DG_LOG/killed.log"
        kill -KILL \$\$
      fi
      if [ "\${DG_MV_AFTER:-}" = "tamper:\$n" ] || [ "\${DG_MV_AFTER:-}" = "notice:\$n" ]; then
        "$REAL_MV" "\$@" || exit \$?
        for f in "\$SESSION_SCHEDULER_HOME"/prompts/*-verdict-????????????????.md; do
          [ -f "\$f" ] || continue
          case "\$DG_MV_AFTER" in
            tamper:*) printf 'tamper' >> "\$f" ;;
            notice:*) : > "\${f%.md}-notice.md" ;;
          esac
        done
        exit 0
      fi
    fi ;;
esac
exec "$REAL_MV" "\$@"
EOF
cat > "$SHIM/jq" <<EOF
#!/usr/bin/env bash
# DG_JQ_FAIL_PAT / DG_JQ_EMPTY_PAT: fail (rc 1) or print nothing (rc 0) when an argument contains the pattern.
# DG_JQ_FAIL_CN=1: fail only the serializer-style first argument -cn.
a=""
for x in "\$@"; do a="\$a\$x"; done
if [ -n "\${DG_JQ_FAIL_PAT:-}" ] && [[ "\$a" == *"\$DG_JQ_FAIL_PAT"* ]]; then exit 1; fi
if [ -n "\${DG_JQ_EMPTY_PAT:-}" ] && [[ "\$a" == *"\$DG_JQ_EMPTY_PAT"* ]]; then cat >/dev/null 2>&1; exit 0; fi
if [ "\${DG_JQ_FAIL_CN:-}" = 1 ] && [ "\${1:-}" = "-cn" ]; then exit 1; fi
exec "$REAL_JQ" "\$@"
EOF
cat > "$SHIM/grep" <<EOF
#!/usr/bin/env bash
# DG_FLIP_META=<manifest> DG_FLIP_AFTER=<n>: after the n-th grep that reads that session-chat
# manifest, rewrite it to a version below the durable-inbox floor. A caller that checks the
# install twice sees two different answers; a caller that checks once does not.
"$REAL_GREP" "\$@"; rc=\$?
if [ -n "\${DG_FLIP_META:-}" ]; then
  for a in "\$@"; do
    if [ "\$a" = "\$DG_FLIP_META" ]; then
      n=\$(cat "\$DG_LOG/flipcount" 2>/dev/null || echo 0); n=\$((n + 1)); echo "\$n" > "\$DG_LOG/flipcount"
      [ "\$n" = "\${DG_FLIP_AFTER:-1}" ] && printf '{ "name": "session-chat", "version": "0.1.0" }\\n' > "\$DG_FLIP_META"
    fi
  done
fi
exit \$rc
EOF
cat > "$SHIM/od" <<EOF
#!/usr/bin/env bash
if [ "\${DG_OD_FAIL_N8:-}" = 1 ]; then case "\$*" in *-N8*) exit 1 ;; esac; fi
exec "$REAL_OD" "\$@"
EOF
cat > "$SHIM/mkdir" <<EOF
#!/usr/bin/env bash
# DG_MKDIR_RO=1: a task lock directory is created read-only, so the holder pid cannot be written.
if [ "\${DG_MKDIR_RO:-}" = 1 ]; then
  for last in "\$@"; do :; done
  case "\$last" in
    *.lock) "$REAL_MKDIR" "\$@" && chmod 500 "\$last"; exit \$? ;;
  esac
fi
exec "$REAL_MKDIR" "\$@"
EOF
chmod +x "$SHIM"/*

# A PATH directory of symlinks to every tool on the system PATH except the named ones.
mk_pathdir() { # mk_pathdir <dir> <excluded-name...>
  local dir="$1" d f n x skip; shift
  mkdir -p "$dir"
  local IFS=:
  for d in $PATH; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      [ -x "$f" ] && [ ! -d "$f" ] || continue
      n="${f##*/}"; skip=0
      for x in "$@"; do [ "$n" = "$x" ] && skip=1; done
      [ "$skip" = 1 ] && continue
      [ -e "$dir/$n" ] || ln -s "$f" "$dir/$n" 2>/dev/null
    done
  done
}
NOJQ_PATH="$ROOT/path-nojq"; mk_pathdir "$NOJQ_PATH" jq
NOPY_PATH="$ROOT/path-nopy"; mk_pathdir "$NOPY_PATH" python3 python
FULL_PATH="$ROOT/path-full"; mk_pathdir "$FULL_PATH"

# ------------------------------------------------------------ chat roots -----
# Hybrid session-chat root: the REAL lib.sh and own-draft-check.sh next to
# recording stubs. Behaviour per target comes from env: DG_D_<pane> (dispatch:
# delivered|queued|queued3|fail), DG_S_<pane> (send: ok|fail), DG_HOOK_<pane>
# (a script run before a dispatch returns).
mk_chat() { # mk_chat <dir> [with-helper|no-helper]
  local d="$1"
  mkdir -p "$d/scripts" "$d/.claude-plugin"
  printf '{ "name": "session-chat", "version": "0.17.0" }\n' > "$d/.claude-plugin/plugin.json"
  cp "$CHAT_SRC/lib.sh" "$d/scripts/"
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s" "${SESSION_CHAT_PANE_NAME:-}"' > "$d/scripts/get-my-name.sh"
  [ "${2:-with-helper}" = with-helper ] && cp "$CHAT_SRC/own-draft-check.sh" "$d/scripts/"
  cat > "$d/scripts/dispatch-to-session.sh" <<'STUB'
#!/usr/bin/env bash
t="$1"; k="${t//-/_}"
echo "dispatch $t" >> "$DG_LOG/transport.log"
hook="DG_HOOK_$k"; [ -n "${!hook:-}" ] && bash "${!hook}" "$t" "$2"
mode="DG_D_$k"
case "${!mode:-delivered}" in
  delivered) echo "Dispatched task to '$t'"; echo "Message id: aaaaaaaaaaaaaaaa"; exit 0 ;;
  queued)    echo "Queued dispatch to '$t' — recipient was busy; it will arrive on their next turn."; echo "Message id: bbbbbbbbbbbbbbbb"; exit 0 ;;
  queued3)   echo "Message id: cccccccccccccccc"; exit 3 ;;
  *)         echo "stub hard failure" >&2; exit 1 ;;
esac
STUB
  cat > "$d/scripts/send-message.sh" <<'STUB'
#!/usr/bin/env bash
t="$1"; k="${t//-/_}"
echo "send $t" >> "$DG_LOG/transport.log"
mode="DG_S_$k"
[ "${!mode:-ok}" = fail ] && exit 1
exit 0
STUB
  chmod 644 "$d/scripts"/*.sh
}
CHAT="$ROOT/chat"; mk_chat "$CHAT" with-helper
CHAT_OLD="$ROOT/chat-old"; mk_chat "$CHAT_OLD" no-helper
# Checker stub chats: own-draft-check.sh answers from DG_CHK_RC / DG_CHK_OUT.
mk_chat_checker() { # mk_chat_checker <dir>
  mk_chat "$1" no-helper
  cat > "$1/scripts/own-draft-check.sh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = "--consume" ]; then echo "NOTE: kept draft (stub): $2"; exit 0; fi
[ -n "${DG_CHK_OUT:-}" ] && printf '%b' "$DG_CHK_OUT"
exit "${DG_CHK_RC:-0}"
STUB
  chmod 644 "$1/scripts/own-draft-check.sh"
}
CHAT_CHK="$ROOT/chat-chk"; mk_chat_checker "$CHAT_CHK"
# Race hook: add a contract to the task while the pane name is read (after the
# early contract check, before the locked write).
CHAT_RACE="$ROOT/chat-race"; mk_chat "$CHAT_RACE" with-helper
cat > "$CHAT_RACE/scripts/get-my-name.sh" <<'STUB'
#!/usr/bin/env bash
printf "%s" "${SESSION_CHAT_PANE_NAME:-}"
if [ -n "${DG_RACE_TASK:-}" ]; then
  f="$SESSION_SCHEDULER_HOME/tasks/$DG_RACE_TASK.json"
  jq '.contract = {"raced": true}' "$f" > "$f.race" && mv "$f.race" "$f"
fi
STUB
chmod 644 "$CHAT_RACE/scripts/get-my-name.sh"
# Lock hook: take the task lock with a LIVE pid (the next lock attempt times out).
cat > "$ROOT/hook-lock.sh" <<'STUB'
#!/usr/bin/env bash
l="$SESSION_SCHEDULER_HOME/locks/$DG_LOCK_ID.lock"
mkdir "$l" 2>/dev/null && echo "$DG_LOCK_PID" > "$l/pid"
STUB

# --------------------------------------------------------------- running -----
FXN=0
new_fx() {
  FXN=$((FXN + 1)); FX="$ROOT/fx$FXN"
  mkdir -p "$FX/home" "$FX/msgs/drafts/rev1" "$FX/msgs/drafts/other1" "$FX/msgs/drafts/boss1" "$FX/log"
  chmod 700 "$FX/msgs" "$FX/msgs/drafts" "$FX/msgs/drafts/rev1" "$FX/msgs/drafts/other1" "$FX/msgs/drafts/boss1"
  : > "$FX/log/transport.log"
}
RUN_ENV=()
# run <pane> <script> args...  ->  RC OUT ERR (clean environment per call)
run() {
  local pane="$1" script="$2"; shift 2
  local sd="${S_DIR:-$SCRIPTS}"
  env -i PATH="${RUN_PATH:-$SHIM:$FULL_PATH}" HOME="$HOME" TMPDIR="${TMPDIR:-/tmp}" LANG=C \
    SESSION_SCHEDULER_HOME="${RUN_HOME-$FX/home}" SESSION_CHAT_ROOT_OVERRIDE="${CHAT_USE:-$CHAT}" \
    SESSION_CHAT_PANE_NAME="$pane" SESSION_CHAT_TARGET_MESSAGES_DIR="$FX/msgs" DG_LOG="$FX/log" \
    DG_LOCK_PID="$HOLD_PID" \
    ${RUN_ENV[@]+"${RUN_ENV[@]}"} "$BASH_BIN" "$sd/$script" "$@" >"$FX/out" 2>"$FX/err"
  RC=$?
  OUT=$(<"$FX/out"); ERR=$(<"$FX/err")
  RUN_ENV=(); RUN_PATH=""; CHAT_USE=""; unset RUN_HOME
}
# mk_task <created|assigned|review> [reviewer] -> TID. Setup is quiet; the
# transport log and the mv counter are reset so the run under test starts clean.
mk_task() {
  local st="$1" rv="${2:-}"
  if [ -n "$rv" ]; then run boss1 task-new.sh "dg task" --reviewer "$rv"; else run boss1 task-new.sh "dg task"; fi
  TID=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}')
  [ "$st" = created ] || run boss1 task-assign.sh worker1 "$TID" "do the thing"
  [ "$st" != review ] || run worker1 task-review.sh "$TID" "sha abc"
  : > "$FX/log/transport.log"; rm -f "$FX/log/mvcount" "$FX/log/flipcount"
  rm -rf "$FX/home/locks/$TID.lock"
}
mk_draft() { # mk_draft <pane> <name> <content> -> DRAFT
  DRAFT="$FX/msgs/drafts/$1/$2"; printf '%s' "$3" > "$DRAFT"
}
tf() { printf '%s/tasks/%s.json' "$FX/home" "$1"; }
tcount() { # tcount <dispatch|send> <target>
  local n; n=$(grep -c "^$1 $2\$" "$FX/log/transport.log" 2>/dev/null); printf '%s' "${n:-0}"
}
release_locks() { rm -rf "$FX/home/locks/"*.lock 2>/dev/null; }

# ----------------------------------------------------------------- DIAG ------
SCHED_VERSION=$(jq -r .version "$SCRIPTS/../.claude-plugin/plugin.json" 2>/dev/null)
EXERCISED="$ROOT/exercised.txt"; : > "$EXERCISED"
dg_lines() { printf '%s\n' "$ERR" | grep '^DIAG ' || true; }
dg_count() { local n; n=$(dg_lines | grep -c '^DIAG '); printf '%s' "${n:-0}"; }
dg_get() { dg_lines | sed -n "${1}p" | sed 's/^DIAG //'; }
dgf() { dg_get "$1" | jq -r "$2" 2>/dev/null; }
# The fixed diag/1 shape: exact key set, closed enums, typed values.
dg_valid() {
  printf '%s' "$1" | jq -e '
    (keys == ["also","also_truncated","emitter","event","generation","helper","notification","outcome","phase","reason","request","schema","state_committed","subject","task","version"])
    and .schema == "diag/1" and .emitter == "scheduler"
    and (.helper | IN("task-done.sh","task-block.sh","task-review.sh"))
    and (.subject | IN("transition","assigner_ack","reviewer_request","verdict_event","duration","lock","bookkeeping","admission"))
    and (.phase | IN("argv","validate","admission","transition","notify","cleanup"))
    and (.reason | test("^sched\\.[a-z_]+\\.[a-z_]+$"))
    and (.outcome | IN("refused","failed","partial"))
    and (.state_committed | type == "boolean" or . == null)
    and (.notification == null or ((.notification | keys) == ["for","observed","persisted"]
        and (.notification.for | IN("assigner_ack","reviewer_request","verdict_event"))
        and (.notification.observed == null or (.notification.observed | IN("delivered","queued","inline-fallback","failed")))
        and (.notification.persisted == null or (.notification.persisted | IN("pending","delivered","queued","inline-fallback","failed","not-required","unknown")))))
    and (.task == null or (.task | type == "string" and length <= 128 and test("^[A-Za-z0-9_-]+$")))
    and (.generation == null or (.generation | type == "number" and . >= 0 and . == floor))
    and (.event == null or (.event | test("^[a-f0-9]{8,16}$")))
    and (.request == null or (.request | test("^[a-f0-9]{8,16}$")))
    and (.also | type == "array" and length <= 4 and all(.[]; test("^sched\\.[a-z_]+\\.[a-z_]+$")))
    and (.also_truncated | type == "boolean")
    and (.version == null or (.version | test("^[0-9]+\\.[0-9]+\\.[0-9]+$")))' >/dev/null 2>&1
}
# Registered (subject, phase, outcome) triple for the emitted reason.
dg_registered() { # dg_registered <json>
  jq -e --argjson d "$1" '.codes[] | select(.code == $d.reason)
    | (.subjects | index($d.subject)) != null and (.phases | index($d.phase)) != null and (.outcomes | index($d.outcome)) != null' "$REGISTRY" >/dev/null 2>&1
}
# dg_expect <n> <reason> <subject> <phase> <outcome> <committed: true|false|null>
dg_expect() {
  local j; j=$(dg_get "$1")
  if [ -z "$j" ]; then bad="$bad [no DIAG #$1 (wanted $2)]"; return 1; fi
  dg_valid "$j" || { bad="$bad [invalid schema #$1: $j]"; return 1; }
  dg_registered "$j" || { bad="$bad [#$1 not registered as $3/$4/$5: $j]"; return 1; }
  printf '%s' "$j" | jq -e --arg r "$2" --arg s "$3" --arg p "$4" --arg o "$5" --argjson c "$6" \
    '.reason == $r and .subject == $s and .phase == $p and .outcome == $o and .state_committed == $c' >/dev/null 2>&1 \
    || { bad="$bad [DIAG #$1 mismatch wanted $2 $3 $4 $5 $6: $j]"; return 1; }
  echo "$2" >> "$EXERCISED"
}
# dg_notif <n> <for> <observed|null> <persisted|null>
dg_notif() {
  dg_get "$1" | jq -e --arg f "$2" --arg o "$3" --arg p "$4" \
    '.notification.for == $f and (.notification.observed // "null") == $o and (.notification.persisted // "null") == $p' >/dev/null 2>&1 \
    || bad="$bad [notification #$1 wanted $2/$3/$4: $(dg_get "$1")]"
}
dg_also() { # dg_also <n> <code>: the code is in .also
  dg_get "$1" | jq -e --arg c "$2" '.also | index($c) != null' >/dev/null 2>&1 || bad="$bad [DIAG #$1 also lacks $2]"
}
dg_none() { [ "$(dg_count)" = 0 ] || bad="$bad [unexpected DIAG: $(dg_lines | head -1)]"; }
dg_n() { [ "$(dg_count)" = "$1" ] || bad="$bad [DIAG count $(dg_count) != $1]"; }
human_first() { # the first DIAG line comes after at least one human line
  local first; first=$(printf '%s\n' "$ERR" | grep -n '^DIAG ' | head -1 | cut -d: -f1)
  [ -n "$first" ] && [ "$first" -gt 1 ] || bad="$bad [DIAG not preceded by human text]"
}
status_of() { jq -r .status "$(tf "$1")"; }

echo "=== session-scheduler diagnostics tests (scripts: $SCRIPTS) ==="

HELPERS="task-done.sh task-block.sh task-review.sh"

# ================================================================ ENV ========
# Bootstrap and environment faults (before any task is read).
new_fx
for h in $HELPERS; do
  mk_task assigned rev1
  RUN_HOME=""; run worker1 "$h" "$TID" "note"
  ck "$h rc" [ "$RC" = 1 ]
  ck "$h unchanged" [ "$(status_of "$TID")" = assigned ]
  dg_n 1; dg_expect 1 sched.env.home_unset transition validate refused false
  ck "$h helper field" [ "$(dgf 1 .helper)" = "$h" ]
  ck "$h version" [ "$(dgf 1 .version)" = "$SCHED_VERSION" ]
  human_first
  run worker1 "$h" "$TID" "note"; ck "$h control rc" [ "$RC" = 0 ]; dg_none
done
finish "diag_env_home_unset_each_helper_with_control"

for h in $HELPERS; do
  mk_task assigned rev1
  RUN_PATH="$NOJQ_PATH"; run worker1 "$h" "$TID" "note"
  ck "$h rc" [ "$RC" = 1 ]
  ck "$h unchanged" [ "$(status_of "$TID")" = assigned ]
  dg_n 1
  want='DIAG {"schema":"diag/1","emitter":"scheduler","helper":"'$h'","version":null,"subject":"transition","phase":"validate","reason":"sched.env.jq_missing","outcome":"refused","state_committed":false,"notification":null,"task":null,"generation":null,"event":null,"request":null,"also":[],"also_truncated":false}'
  ck "$h fixed bootstrap record" [ "$(dg_lines)" = "$want" ]
  dg_expect 1 sched.env.jq_missing transition validate refused false
  human_first
  RUN_PATH="$FULL_PATH"; run worker1 "$h" "$TID" "note"; ck "$h control rc" [ "$RC" = 0 ]; dg_none
done
finish "diag_env_jq_missing_fixed_bootstrap_record_with_control"

new_fx; mk_task assigned rev1
RUN_ENV=(AGENT_PLUGINS_TIME_ZONE=Not/AZone); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.env.timezone_invalid transition validate refused false; human_first
RUN_ENV=(AGENT_PLUGINS_TIME_ZONE=UTC); run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_env_timezone_invalid_with_control"

# Store faults.
new_fx; mk_task assigned rev1
mv "$FX/home/tasks" "$FX/tasks-real"; ln -s "$FX/tasks-real" "$FX/home/tasks"
run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(jq -r .status "$FX/tasks-real/$TID.json")" = assigned ]
dg_n 1; dg_expect 1 sched.store.unsafe transition validate refused false; human_first
rm "$FX/home/tasks"; mv "$FX/tasks-real" "$FX/home/tasks"
run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_store_unsafe_symlinked_tasks_dir_with_control"

new_fx; : > "$FX/blocker"
RUN_HOME="$FX/blocker/sub"; run worker1 task-done.sh any ok
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.store.unavailable transition validate failed false; human_first
mk_task assigned rev1; run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_store_unavailable_uncreatable_root_with_control"

# ================================================================ ARGV =======
new_fx
for h in task-block.sh task-review.sh; do
  mk_task assigned rev1
  run worker1 "$h" "$TID"
  ck "$h rc" [ "$RC" = 1 ]; ck "$h unchanged" [ "$(status_of "$TID")" = assigned ]
  dg_n 1; dg_expect 1 sched.argv.usage transition argv refused false; human_first
  ck "$h task id" [ "$(dgf 1 .task)" = "$TID" ]
  run worker1 "$h" "$TID" "a reason"; ck "$h control" [ "$RC" = 0 ]; dg_none
done
mk_task assigned rev1; run worker1 task-block.sh
ck "block no args rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.argv.usage transition argv refused false
ck "no task id recorded" [ "$(dgf 1 .task)" = null ]
finish "diag_argv_usage_block_and_review_with_control"

new_fx; mk_task assigned rev1
run worker1 task-done.sh
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.argv.task_id_missing transition argv refused false; human_first
run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_argv_task_id_missing_with_control"

new_fx; mk_task assigned rev1
for h in $HELPERS; do
  run worker1 "$h" "bad id" "note"
  ck "$h rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.argv.task_id_invalid transition argv refused false; human_first
  ck "$h id not echoed" [ "$(dgf 1 .task)" = null ]
done
run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_argv_task_id_invalid_each_helper_with_control"

new_fx; mk_task assigned rev1
for h in $HELPERS; do
  run worker1 "$h" "no-such-task" "note"
  ck "$h rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.task.not_found transition validate refused false; human_first
  ck "$h id" [ "$(dgf 1 .task)" = "no-such-task" ]
done
run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_task_not_found_each_helper_with_control"

# An uncontracted task given --note-file plus --generation: refused (rc 2) with the
# offered number recorded; the same words WITHOUT --note-file stay accepted as note text.
new_fx; mk_task review rev1; mk_draft rev1 d-1.md "verdict body"
run rev1 task-done.sh "$TID" --generation 3 --note-file "$DRAFT"
ck rc [ "$RC" = 2 ]; ck unchanged [ "$(status_of "$TID")" = review ]
dg_n 1; dg_expect 1 sched.argv.generation_without_contract transition argv refused false; human_first
ck "generation recorded" [ "$(dgf 1 .generation)" = 3 ]
ck draft_kept [ -f "$DRAFT" ]; ck no_dispatch [ "$(tcount dispatch boss1)" = 0 ]
run rev1 task-done.sh "$TID" --generation 12abc --note-file "$DRAFT"
dg_n 1; ck "non-numeric generation is null" [ "$(dgf 1 .generation)" = null ]
run rev1 task-block.sh "$TID" --generation 7 --note-file "$DRAFT"
dg_n 1; dg_expect 1 sched.argv.generation_without_contract transition argv refused false
run rev1 task-done.sh "$TID" --note-file "$DRAFT"; ck "control rc" [ "$RC" = 0 ]; dg_none
mk_task review rev1
run rev1 task-done.sh "$TID" --generation 3 inline note text
ck "inline --generation is plain note text (accepted ordinary form)" [ "$RC" = 0 ]; dg_none
ck "note text kept" [ "$(jq -r '.history[-1].note' "$(tf "$TID")")" = "--generation 3 inline note text" ]
finish "diag_argv_generation_without_contract_note_file_with_controls"

new_fx; mk_task review rev1
for variant in "--note-file" "--note-file:"; do
  if [ "$variant" = "--note-file" ]; then run rev1 task-done.sh "$TID" --note-file; else run rev1 task-block.sh "$TID" --note-file ""; fi
  ck "rc $variant" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.option_malformed verdict_event argv refused false; human_first
done
mk_draft rev1 d-2.md "ok body"
run rev1 task-done.sh "$TID" --note-file "$DRAFT" --note-file "$DRAFT"
ck "repeated rc" [ "$RC" = 1 ]; dg_n 1
ck unchanged [ "$(status_of "$TID")" = review ]
run rev1 task-done.sh "$TID" --note-file "$DRAFT"; ck control [ "$RC" = 0 ]; dg_none
finish "diag_note_file_option_malformed_with_control"

# ================================================================ LOCKS ======
new_fx; mk_task assigned rev1
mkdir "$FX/home/locks/$TID.lock"; echo "$HOLD_PID" > "$FX/home/locks/$TID.lock/pid"
RUN_ENV=(SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.lock.timeout lock transition failed false; human_first
ck "dispatch not attempted" [ "$(tcount dispatch boss1)" = 0 ]
release_locks; run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_lock_timeout_with_control"

new_fx; mk_task assigned rev1
ln -s "$FX/nowhere" "$FX/home/locks/$TID.lock"
run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.lock.unsafe lock transition refused false; human_first
rm -f "$FX/home/locks/$TID.lock"; run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_lock_unsafe_symlinked_lock_with_control"

new_fx; mk_task assigned rev1
RUN_ENV=(DG_MKDIR_RO=1); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.lock.holder_unwritable lock transition failed false; human_first
release_locks; run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_lock_holder_unwritable_with_control"

# Release failure after a SUCCESSFUL transition (no assigner, no reviewer: nothing else runs).
new_fx
run "" task-new.sh "solo"; SID=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}')
run "" task-assign.sh worker1 "$SID" "do it"
RUN_ENV=(DG_MKTEMP_FAIL_RELEASE=1); run worker1 task-review.sh "$SID" "sha1"
ck rc [ "$RC" = 0 ]; ck status [ "$(status_of "$SID")" = review ]
dg_n 1; dg_expect 1 sched.lock.release_failed lock cleanup failed true
release_locks
run "" task-new.sh "solo2"; SID2=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}'); run "" task-assign.sh worker1 "$SID2" "do it"
run worker1 task-review.sh "$SID2" "sha1"; ck control [ "$RC" = 0 ]; dg_none
finish "diag_lock_release_failed_after_success_with_control"

# ================================================================ TRANSITION =
new_fx; mk_task assigned rev1
CHAT_USE="$CHAT_RACE"; RUN_ENV=(DG_RACE_TASK="$TID"); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck "still assigned" [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.contract.legacy_write_refused transition transition refused false; human_first
mk_task assigned rev1
CHAT_USE="$CHAT_RACE"; run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_contract_legacy_write_refused_race_with_control"

# Illegal transitions (pre-commit refusal) with --force as the valid control.
new_fx
mk_task created rev1
run worker1 task-done.sh "$TID" "why"
ck "done rc" [ "$RC" = 1 ]; ck "done unchanged" [ "$(status_of "$TID")" = created ]
dg_n 1; dg_expect 1 sched.transition.illegal transition transition refused false; human_first
ck "done task id" [ "$(dgf 1 .task)" = "$TID" ]
run worker1 task-review.sh "$TID" "sha"
ck "review rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.transition.illegal transition transition refused false
mk_task assigned rev1; run worker1 task-done.sh "$TID" "fine"; run worker1 task-block.sh "$TID" "from done"
ck "block rc" [ "$RC" = 1 ]; ck "block unchanged" [ "$(status_of "$TID")" = "done" ]
dg_n 1; dg_expect 1 sched.transition.illegal transition transition refused false
mk_task created rev1
run worker1 task-done.sh "$TID" --force "forced"; ck "forced control rc" [ "$RC" = 0 ]; dg_none
ck "forced status" [ "$(status_of "$TID")" = "done" ]
finish "diag_transition_illegal_done_review_block_with_force_control"

new_fx; mk_task assigned rev1
RUN_ENV=(DG_JQ_EMPTY_PAT='.status = $status'); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.ledger.write_refused transition transition refused false; human_first
run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_ledger_write_refused_with_control"

new_fx; mk_task assigned rev1
RUN_ENV=(DG_MV_FAIL=1); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = assigned ]
dg_n 1; dg_expect 1 sched.ledger.write_failed transition transition failed false; human_first
ck "no ack after a refused transition" [ "$(tcount dispatch boss1)" = 0 ]
rm -f "$FX/log/mvcount"; run worker1 task-done.sh "$TID" ok; ck control [ "$RC" = 0 ]; dg_none
finish "diag_ledger_write_failed_with_control"

# Duration bookkeeping failure: the transition stands, the record fails.
new_fx; mk_task assigned rev1
RUN_ENV=(DG_MV_FAIL=2); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 0 ]; ck status [ "$(status_of "$TID")" = "done" ]
ck "duration absent" [ "$(jq -r '.duration_seconds // "none"' "$(tf "$TID")")" = none ]
dg_n 1; dg_expect 1 sched.duration.record_failed duration transition partial true; dg_also 1 sched.ledger.write_failed; human_first
ck "ack still sent" [ "$(tcount dispatch boss1)" = 1 ]
mk_task assigned rev1; run worker1 task-done.sh "$TID" ok; ck "control rc" [ "$RC" = 0 ]; dg_none
ck "control duration recorded" [ "$(jq -r '.duration_seconds // "none"' "$(tf "$TID")")" != none ]
finish "diag_duration_record_failed_with_control"

# ============================================================ ASSIGNER ACK ===
# Ordinary ack outcomes for each helper: failed, inline-fallback, queued/delivered control.
new_fx
for h in $HELPERS; do
  mk_task assigned rev1
  [ "$h" = task-review.sh ] && TARGS=(sha) || TARGS=(why)
  RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run worker1 "$h" "$TID" "${TARGS[@]}"
  ck "$h rc" [ "$RC" = 0 ]
  dg_expect 1 sched.notify.failed assigner_ack notify partial true; dg_notif 1 assigner_ack failed failed; human_first
  ckx "$h WARN first" '[ "$(printf "%s\n" "$ERR" | head -1 | cut -c1-4)" = WARN ]'
  dg_n 1
  ck "$h transports" [ "$(tcount dispatch boss1)" = 1 ] ; ck "$h send" [ "$(tcount send boss1)" = 1 ]
  ck "$h ack recorded failed" [ "$(jq -r .meta.last_ack.status "$(tf "$TID")")" = failed ]
  mk_task assigned rev1
  RUN_ENV=(DG_D_boss1=fail DG_S_boss1=ok); run worker1 "$h" "$TID" "${TARGS[@]}"
  ck "$h inline rc" [ "$RC" = 0 ]
  dg_expect 1 sched.notify.inline_fallback assigner_ack notify partial true; dg_notif 1 assigner_ack inline-fallback inline-fallback
  ck "$h inline transports" [ "$(tcount dispatch boss1)" = 1 ] ; ck "$h inline send" [ "$(tcount send boss1)" = 1 ]
  for mode in delivered queued queued3; do
    mk_task assigned rev1
    RUN_ENV=(DG_D_boss1="$mode"); run worker1 "$h" "$TID" "${TARGS[@]}"
    ck "$h $mode control rc" [ "$RC" = 0 ]; dg_none
    ck "$h $mode recorded dispatched" [ "$(jq -r .meta.last_ack.status "$(tf "$TID")")" = dispatched ]
  done
done
finish "diag_notify_assigner_ack_failed_inline_fallback_with_delivered_queued_controls"

# Fix 3: last_ack lock failure used to be silent apart from the lock ERROR (rc 0).
new_fx
for h in $HELPERS; do
  for mode in delivered queued; do
    mk_task assigned
    [ "$h" = task-review.sh ] && TARGS=(sha) || TARGS=(why)
    RUN_ENV=(DG_D_boss1="$mode" DG_HOOK_boss1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 "$h" "$TID" "${TARGS[@]}"
    ck "$h $mode rc unchanged" [ "$RC" = 0 ]
    ckx "$h $mode lock text unchanged" 'printf "%s" "$ERR" | grep -q "could not lock task $TID"'
    dg_n 1; dg_expect 1 sched.bookkeeping.last_ack_failed bookkeeping notify partial true
    dg_notif 1 assigner_ack "$mode" unknown; dg_also 1 sched.lock.timeout
    ck "$h $mode no last_ack recorded" [ "$(jq -r '.meta.last_ack // "none"' "$(tf "$TID")")" = none ]
    release_locks
  done
done
mk_task assigned; run worker1 task-done.sh "$TID" why; ck "control rc" [ "$RC" = 0 ]; dg_none
ck "control last_ack recorded" [ "$(jq -r .meta.last_ack.status "$(tf "$TID")")" = dispatched ]
finish "diag_bookkeeping_last_ack_failed_with_control"

# ============================================================ VERDICT EVENT ==
# --note-file path: ONE event; the notification outcome is recorded on the event.
vnew() { mk_task review rev1; mk_draft rev1 "d-$RANDOM.md" "verdict body $RANDOM"; }
new_fx
for h in task-done.sh task-block.sh; do
  vnew
  RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run rev1 "$h" "$TID" --note-file "$DRAFT"
  ck "$h rc" [ "$RC" = 0 ]
  dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event failed failed
  ckx "$h event id" '[[ "$(dgf 1 .event)" =~ ^[a-f0-9]{16}$ ]]'
  ck "$h event matches ledger" [ "$(dgf 1 .event)" = "$(jq -r '.meta.verdict_events | keys[0]' "$(tf "$TID")")" ]
  ck "$h state failed" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = failed ]
  ckx "$h partial WARN" 'printf "%s" "$ERR" | grep -q "partial success"'; human_first
  ck "$h one dispatch + one inline attempt" [ "$(tcount dispatch boss1)" = 1 ]
  ck "$h send" [ "$(tcount send boss1)" = 1 ]
  vnew
  RUN_ENV=(DG_D_boss1=fail DG_S_boss1=ok); run rev1 "$h" "$TID" --note-file "$DRAFT"
  ck "$h inline rc" [ "$RC" = 0 ]; dg_n 1
  dg_expect 1 sched.notify.inline_fallback verdict_event notify partial true; dg_notif 1 verdict_event inline-fallback inline-fallback
  for mode in delivered queued queued3; do
    vnew
    RUN_ENV=(DG_D_boss1="$mode"); run rev1 "$h" "$TID" --note-file "$DRAFT"
    ck "$h $mode control rc" [ "$RC" = 0 ]; dg_none
    want=delivered; [ "$mode" = delivered ] || want=queued
    ck "$h $mode recorded" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = "$want" ]
  done
done
finish "diag_notify_verdict_event_failed_inline_fallback_with_controls"

new_fx
for h in task-done.sh task-block.sh; do
  # outcome record fails (lock held while the notice is dispatched): delivered but unrecorded
  vnew
  RUN_ENV=(DG_HOOK_boss1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run rev1 "$h" "$TID" --note-file "$DRAFT"
  ck "$h rc" [ "$RC" = 0 ]; dg_n 1
  dg_expect 1 sched.notify.record_failed verdict_event notify partial true; dg_notif 1 verdict_event delivered pending; dg_also 1 sched.lock.timeout
  ck "$h state stays pending" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = pending ]
  ckx "$h WARN text" 'printf "%s" "$ERR" | grep -q "could not record the notification outcome"'
  release_locks
  # primary failure + failed record: first fault wins, the record failure is secondary
  vnew
  RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail DG_HOOK_boss1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run rev1 "$h" "$TID" --note-file "$DRAFT"
  dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event failed pending
  dg_also 1 sched.notify.record_failed; dg_also 1 sched.lock.timeout
  release_locks
done
vnew; run rev1 task-done.sh "$TID" --note-file "$DRAFT"; ck "control rc" [ "$RC" = 0 ]; dg_none
finish "diag_notify_record_failed_first_fault_wins_with_control"

new_fx
for h in task-done.sh task-block.sh; do
  vnew
  RUN_ENV=(DG_JQ_FAIL_PAT='notification.state'); run rev1 "$h" "$TID" --note-file "$DRAFT"
  ck "$h rc" [ "$RC" = 0 ]; ck "$h transition committed" [ "$(status_of "$TID")" != review ]
  dg_n 1; dg_expect 1 sched.notify.state_unreadable verdict_event notify partial true; dg_notif 1 verdict_event null unknown
  ck "$h no notification attempted" [ "$(tcount dispatch boss1)" = 0 ]
  ckx "$h event id" '[[ "$(dgf 1 .event)" =~ ^[a-f0-9]{16}$ ]]'
done
vnew; run rev1 task-done.sh "$TID" --note-file "$DRAFT"; ck "control rc" [ "$RC" = 0 ]; dg_none
# not-required (assigner is the actor) is a normal outcome, never a diagnostic
mk_task review rev1; mk_draft boss1 d-nr.md "self verdict"
run boss1 task-done.sh "$TID" --note-file "$DRAFT"; ck "not-required rc" [ "$RC" = 0 ]; dg_none
ck "not-required state" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = not-required ]
finish "diag_notify_state_unreadable_with_not_required_control"

# ============================================================== NOTE FILE ====
# nf_untouched: refusal left the task, artifacts, draft and transport untouched.
nf_untouched() {
  ck "status unchanged" [ "$(status_of "$TID")" = review ]
  ck "no event" [ "$(jq -r '(.meta.verdict_events // {}) | length' "$(tf "$TID")")" = 0 ]
  ckx "no artifact" '[ -z "$(ls "$FX"/home/prompts/"$TID"-verdict-* 2>/dev/null)" ]'
  ck "draft kept" [ -f "$DRAFT" ]
  ck "no dispatch to assigner" [ "$(tcount dispatch boss1)" = 0 ]
}
nf_control() { # a valid note-file run on a fresh task: rc 0, no DIAG
  vnew; run rev1 task-done.sh "$TID" --note-file "$DRAFT"
  ck "control rc" [ "$RC" = 0 ]; dg_none
}

new_fx
vnew; CHAT_USE="$CHAT_OLD"; run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.checker_unavailable verdict_event validate refused false; human_first; nf_untouched
nf_control
finish "diag_note_file_checker_unavailable_old_chat_with_control"

new_fx
vnew; RUN_PATH="$NOPY_PATH"; run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.python_missing verdict_event validate refused false; human_first; nf_untouched
nf_control
finish "diag_note_file_python_missing_with_control"

new_fx
PLUG="$ROOT/plug-novf"; rm -rf "$PLUG"; cp -R "$SCRIPTS/.." "$PLUG"; rm -f "$PLUG/scripts/verdict-file.py"
vnew; S_DIR="$PLUG/scripts" run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.validator_missing verdict_event validate refused false; human_first; nf_untouched
ck "python present" command -v python3
nf_control
finish "diag_note_file_validator_missing_distinct_from_python_with_control"

new_fx
vnew; RUN_ENV=(SESSION_SCHEDULER_NOTE_MAX_BYTES=5); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.too_large verdict_event validate refused false; human_first; nf_untouched
nf_control
finish "diag_note_file_too_large_with_control"

new_fx
vnew; CHAT_USE="$CHAT_CHK"; RUN_ENV=(DG_CHK_RC=4); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.changed_during_check verdict_event validate refused false; human_first; nf_untouched
nf_control
finish "diag_note_file_changed_during_check_with_control"

# Any other checker status is check_failed; rc 1 is never read as "not an own draft".
new_fx
vnew
printf 'x' > "$FX/msgs/drafts/other1/foreign.md"
run rev1 task-done.sh "$TID" --note-file "$FX/msgs/drafts/other1/foreign.md"
ck "real checker rc1 (foreign draft)" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.check_failed verdict_event validate refused false; human_first; nf_untouched
ckx "human text unchanged (still says not an eligible own draft)" 'printf "%s" "$ERR" | grep -q "not an eligible own draft"'
for rc in 1 2 127 130; do
  vnew; CHAT_USE="$CHAT_CHK"; RUN_ENV=(DG_CHK_RC="$rc"); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
  ck "stub rc $rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.check_failed verdict_event validate refused false; nf_untouched
done
nf_control
finish "diag_note_file_check_failed_any_other_status_with_control"

new_fx
vnew; CHAT_USE="$CHAT_CHK"; RUN_ENV=(DG_CHK_RC=0 DG_CHK_OUT=garbage); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "garbage rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.check_malformed verdict_event validate refused false; nf_untouched
SHA64=$(printf 'a%.0s' $(seq 1 64))
vnew; CHAT_USE="$CHAT_CHK"; RUN_ENV=(DG_CHK_RC=0 "DG_CHK_OUT=OK\t1:2\t$SHA64\t3\nOK\t1:2\t$SHA64\t3\n"); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "two lines rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.check_malformed verdict_event validate refused false; nf_untouched
vnew; CHAT_USE="$CHAT_CHK"; RUN_ENV=(DG_CHK_RC=0 "DG_CHK_OUT=OK\t1:2\tnot-a-sha\t3\n"); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "bad digest rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.check_malformed verdict_event validate refused false
nf_control
finish "diag_note_file_check_malformed_output_only_with_control"

new_fx
vnew; RUN_ENV=(DG_OD_FAIL_N8=1); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck rc [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.event_id_failed verdict_event validate refused false; human_first; nf_untouched
nf_control
finish "diag_note_file_event_id_failed_with_control"

# Every verdict-file.py refusal is prepare_failed (no finer classification in 1.3a).
new_fx
vnew; printf 'a\0b' > "$DRAFT"
run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "NUL rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.prepare_failed verdict_event validate refused false; human_first; nf_untouched
vnew; : > "$DRAFT"
run rev1 task-block.sh "$TID" --note-file "$DRAFT"
ck "empty rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.prepare_failed verdict_event validate refused false; nf_untouched
vnew; printf '\377\376bad' > "$DRAFT"
run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "non-UTF-8 rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.prepare_failed verdict_event validate refused false; nf_untouched
nf_control
finish "diag_note_file_prepare_failed_all_validator_refusals_with_control"

# ========================================================= REVIEW ROUTING ====
rv_meta() { jq -r ".meta.$2 // \"null\"" "$(tf "$1")"; }
new_fx
# Dispatch failure (reviewer): rc 0, partial, one line; the assigner is independent.
mk_task assigned rev1
RUN_ENV=(DG_D_rev1=fail); run worker1 task-review.sh "$TID" "sha1"
ck rc [ "$RC" = 0 ]; ck "status review" [ "$(status_of "$TID")" = review ]
dg_n 1; dg_expect 1 sched.review.dispatch_failed reviewer_request notify partial true; dg_notif 1 reviewer_request failed failed; human_first
ck "dispatch stamp null" [ "$(rv_meta "$TID" review_dispatched_at)" = null ]
ck "assigner ack delivered" [ "$(tcount dispatch boss1)" = 1 ]; ck "reviewer attempted once" [ "$(tcount dispatch rev1)" = 1 ]
# dispatch-only retry: no new transition => state_committed false
RUN_ENV=(DG_D_rev1=fail); run worker1 task-review.sh "$TID" "sha1"
dg_n 1; dg_expect 1 sched.review.dispatch_failed reviewer_request notify partial false
ck "retry sent no assigner ack" [ "$(tcount dispatch boss1)" = 1 ]
run worker1 task-review.sh "$TID" "sha1"; ck "retry control rc" [ "$RC" = 0 ]; dg_none
ck "retry stamped delivered" [ "$(rv_meta "$TID" review_dispatch_status)" = delivered ]
run worker1 task-review.sh "$TID" "sha1"; ck "duplicate suppressed rc" [ "$RC" = 0 ]; dg_none
ckx "duplicate suppression text" 'printf "%s" "$OUT" | grep -q "Not re-dispatching"'
finish "diag_review_dispatch_failed_retry_committed_false_with_controls"

# Reviewer dispatch ok but the success stamp cannot be recorded (lock held by the dispatch hook).
new_fx
mk_task assigned rev1
RUN_ENV=(DG_HOOK_rev1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-review.sh "$TID" "sha1"
ck rc [ "$RC" = 0 ]
dg_n 1; dg_expect 1 sched.review.record_failed reviewer_request notify partial true; dg_notif 1 reviewer_request delivered unknown; dg_also 1 sched.lock.timeout
ck "request id" [ "$(dgf 1 .request)" = aaaaaaaaaaaaaaaa ]
ckx "existing WARN kept" 'printf "%s" "$ERR" | grep -q "recording review_dispatched_at FAILED"'
release_locks
mk_task assigned rev1; run worker1 task-review.sh "$TID" "sha1"; ck "control rc" [ "$RC" = 0 ]; dg_none
finish "diag_review_record_failed_with_control"

# Failed dispatch AND failed attempt record: two independent operations, two lines.
new_fx
mk_task assigned rev1
RUN_ENV=(DG_D_rev1=fail DG_HOOK_rev1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-review.sh "$TID" "sha1"
ck rc [ "$RC" = 0 ]; dg_n 2
dg_expect 1 sched.review.dispatch_failed reviewer_request notify partial true; dg_notif 1 reviewer_request failed unknown
dg_expect 2 sched.bookkeeping.reviewer_metadata_failed bookkeeping notify partial true; dg_notif 2 reviewer_request failed unknown; dg_also 2 sched.lock.timeout
ck "first line does not inherit the lock fault" [ "$(dgf 1 '.also | length')" = 0 ]
release_locks
finish "diag_review_metadata_failed_independent_line"

# Fix 1: a queued reviewer dispatch is recorded queued (was delivered).
new_fx
for mode in queued queued3; do
  mk_task assigned rev1
  RUN_ENV=(DG_D_rev1="$mode"); run worker1 task-review.sh "$TID" "sha1"
  ck "$mode rc" [ "$RC" = 0 ]; dg_none
  ck "$mode status queued" [ "$(rv_meta "$TID" review_dispatch_status)" = queued ]
  ck "$mode stamped" [ "$(rv_meta "$TID" review_dispatched_at)" != null ]
  ck "$mode reviewer once" [ "$(tcount dispatch rev1)" = 1 ]
done
mk_task assigned rev1; RUN_ENV=(DG_D_rev1=delivered); run worker1 task-review.sh "$TID" "sha1"
ck "delivered control" [ "$(rv_meta "$TID" review_dispatch_status)" = delivered ]; dg_none
run worker1 task-review.sh "$TID" "sha1"; ck "queued-then-rerun is suppressed" [ "$RC" = 0 ]
ck "no second reviewer dispatch" [ "$(tcount dispatch rev1)" = 1 ]
finish "fix1_queued_reviewer_dispatch_recorded_queued_with_delivered_control"

# Fix 2: the review packet write is checked.
new_fx
mk_task assigned rev1
mkdir "$FX/home/prompts/$TID-review.md"
run worker1 task-review.sh "$TID" "sha1"
ck rc [ "$RC" = 0 ]; ck "status review" [ "$(status_of "$TID")" = review ]
dg_n 1; dg_expect 1 sched.review.packet_write_failed reviewer_request notify partial true; dg_notif 1 reviewer_request null null; human_first
ckx "WARN says not to replay" 'printf "%s" "$ERR" | grep -q "do NOT replay the transition"'
ck "no reviewer dispatch" [ "$(tcount dispatch rev1)" = 0 ]; ck "assigner ack sent once" [ "$(tcount dispatch boss1)" = 1 ]
ck "no dispatch stamp" [ "$(rv_meta "$TID" review_dispatched_at)" = null ]
ckx "summary still printed" 'printf "%s" "$OUT" | grep -q "Task $TID moved to review"'
# retry after fixing the cause: dispatch-only (no new ack), committed false semantics on a repeat fault
rmdir "$FX/home/prompts/$TID-review.md"
run worker1 task-review.sh "$TID" "sha1"; ck "retry rc" [ "$RC" = 0 ]; dg_none
ck "retry dispatched reviewer once" [ "$(tcount dispatch rev1)" = 1 ]; ck "retry sent no second ack" [ "$(tcount dispatch boss1)" = 1 ]
ck "retry stamp" [ "$(rv_meta "$TID" review_dispatch_status)" = delivered ]
# repeated fault on a retry: committed false
mk_task assigned rev1; mkdir "$FX/home/prompts/$TID-review.md"
run worker1 task-review.sh "$TID" "sha1"; run worker1 task-review.sh "$TID" "sha1"
dg_n 1; dg_expect 1 sched.review.packet_write_failed reviewer_request notify partial false
ck "still no reviewer dispatch" [ "$(tcount dispatch rev1)" = 0 ]
# control: a writable packet path dispatches the reviewer once
mk_task assigned rev1; run worker1 task-review.sh "$TID" "sha1"
ck "control rc" [ "$RC" = 0 ]; dg_none; ck "control reviewer dispatched" [ "$(tcount dispatch rev1)" = 1 ]
finish "fix2_review_packet_write_checked_no_dispatch_with_controls"

# Independent operations: assigner failure never contaminates the reviewer line.
new_fx
mk_task assigned rev1
RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail DG_D_rev1=queued); run worker1 task-review.sh "$TID" "sha1"
ck rc [ "$RC" = 0 ]; dg_n 1
dg_expect 1 sched.notify.failed assigner_ack notify partial true; dg_notif 1 assigner_ack failed failed
ck "reviewer queued recorded" [ "$(rv_meta "$TID" review_dispatch_status)" = queued ]
ck "assigner: 1 dispatch 1 send" [ "$(tcount dispatch boss1)" = 1 ] && ck "assigner send" [ "$(tcount send boss1)" = 1 ]
ck "reviewer: 1 dispatch 0 send" [ "$(tcount dispatch rev1)" = 1 ] && ck "reviewer send" [ "$(tcount send rev1)" = 0 ]
mk_task assigned rev1
RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail DG_D_rev1=fail DG_S_rev1=fail); run worker1 task-review.sh "$TID" "sha1"
dg_n 2; dg_expect 1 sched.notify.failed assigner_ack notify partial true
dg_expect 2 sched.review.dispatch_failed reviewer_request notify partial true
ck "reviewer line has no assigner codes" [ "$(dgf 2 '.also | length')" = 0 ]
ck "reviewer: no inline send" [ "$(tcount send rev1)" = 0 ]
finish "diag_combination_assigner_failed_reviewer_queued_or_failed_independent"

# ============================================================ COMBINATIONS ===
# Duration failure + assigner notification failure: two independent operations.
new_fx; mk_task assigned rev1
RUN_ENV=(DG_MV_FAIL=2 DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-done.sh "$TID" ok
ck rc [ "$RC" = 0 ]; ck status [ "$(status_of "$TID")" = "done" ]; dg_n 2
dg_expect 1 sched.duration.record_failed duration transition partial true; dg_also 1 sched.ledger.write_failed
dg_expect 2 sched.notify.failed assigner_ack notify partial true; dg_notif 2 assigner_ack failed failed
ck "assigner line has no duration codes" [ "$(dgf 2 '.also | length')" = 0 ]
ck "assigner: 1 dispatch 1 send" [ "$(tcount dispatch boss1)" = 1 ] && ck "send" [ "$(tcount send boss1)" = 1 ]
finish "diag_combination_duration_failure_plus_notification_failure"

# Primary failure + lock-release failure: ONE line, the release fault is secondary.
new_fx; mk_task created rev1
RUN_ENV=(DG_MKTEMP_FAIL_RELEASE=1); run worker1 task-done.sh "$TID" "why"
ck rc [ "$RC" = 1 ]; ck unchanged [ "$(status_of "$TID")" = created ]
dg_n 1; dg_expect 1 sched.transition.illegal transition transition refused false; dg_also 1 sched.lock.release_failed
release_locks
mk_task created rev1; run worker1 task-done.sh "$TID" "why"
dg_n 1; ck "control has no also" [ "$(dgf 1 '.also | length')" = 0 ]
finish "diag_combination_primary_failure_plus_lock_release_failure_in_also"

# Serializer allowlist and bounds, driven through a probe that sources the real
# library as "task-done.sh" (the emitter is enabled by the script name). This is a
# component test of the serializer, not a public-invocation trigger test.
PROBE="$ROOT/probe"; mkdir -p "$PROBE"
cat > "$PROBE/task-done.sh" <<'PROBE_EOF'
#!/usr/bin/env bash
set -uo pipefail
source "$LIB_UNDER_TEST"
for c in $PROBE_CODES; do _sched_diag_note "$c"; done
sched_diag_emit "$@"
PROBE_EOF
probe() { # probe <codes> <emit args...>  -> ERR (the DIAG line), RC
  local codes="$1"; shift
  ERR=$(env -i PATH="$FULL_PATH" SESSION_SCHEDULER_HOME="$FX/home" LIB_UNDER_TEST="${S_DIR:-$SCRIPTS}/lib.sh" PROBE_CODES="$codes" \
    "$BASH_BIN" "$PROBE/task-done.sh" "$@" 2>&1 >/dev/null); RC=$?
}
new_fx
probe "sched.x.one sched.x.two sched.x.three sched.x.four sched.x.five sched.x.six sched.x.seven" subject=transition
ck "bounded rc" [ "$RC" = 0 ]; dg_n 1
ck "primary is the first code" [ "$(dgf 1 .reason)" = sched.x.one ]
ck "also bounded to 4" [ "$(dgf 1 '.also | length')" = 4 ]
ck "truncation marked" [ "$(dgf 1 .also_truncated)" = true ]
ck "also order kept" [ "$(dgf 1 '.also | join(",")')" = "sched.x.two,sched.x.three,sched.x.four,sched.x.five" ]
probe "sched.x.one sched.x.two sched.x.three sched.x.four sched.x.five" subject=transition
ck "exactly 4 secondary codes are not truncated" [ "$(dgf 1 .also_truncated)" = false ]
# hostile values never pass: ids that do not match their syntax become null, one line only
probe "sched.x.one" "task=bad
id\"quote" "event=ZZ" "request=1234567" "generation=-1" "committed=maybe" "nfor=bogus" "nobs=whatever" "npers=x"
ck "one line" [ "$(printf '%s\n' "$ERR" | wc -l | tr -d ' ')" = 1 ]
ck "task null" [ "$(dgf 1 .task)" = null ]; ck "event null" [ "$(dgf 1 .event)" = null ]; ck "request null" [ "$(dgf 1 .request)" = null ]
ck "generation null" [ "$(dgf 1 .generation)" = null ]; ck "committed null" [ "$(dgf 1 .state_committed)" = null ]
ck "bogus notification kind drops the object" [ "$(dgf 1 .notification)" = null ]
probe "sched.x.one" "nfor=assigner_ack" "nobs=whatever" "npers=x"
ck "bogus observed/persisted become null" [ "$(dgf 1 '[.notification.observed, .notification.persisted] | map(. == null) | all')" = true ]
probe "sched.x.one" "task=$(printf 'a%.0s' $(seq 1 129))"; ck "129-char task id is null" [ "$(dgf 1 .task)" = null ]
probe "sched.x.one" "task=$(printf 'a%.0s' $(seq 1 128))"; ck "128-char task id kept" [ "$(dgf 1 '.task | length')" = 128 ]
probe "sched.x.one" "generation=0"; ck "generation 0 kept" [ "$(dgf 1 .generation)" = 0 ]
probe "sched.x.one" "event=0123456789abcdef" "request=01234567"; ck "8 and 16 hex accepted" [ "$(dgf 1 '[.event,.request] | join(",")')" = "0123456789abcdef,01234567" ]
probe "" subject=transition; ck "no code, no line" [ -z "$ERR" ]
finish "diag_serializer_bounds_allowlist_and_one_line"

# ======================================================== CONTRACT PASS-THROUGH
# A positively identified contracted route keeps its output and rc exactly and emits
# NO scheduler DIAG (preflight refusal and engine refusal); the ordinary control emits one.
new_fx
CT_REPO="$FX/ct-repo"; mkdir -p "$CT_REPO"
( cd "$CT_REPO" && git init -q && git config user.email fixture@example.invalid && git config user.name Fixture   && printf '#!/bin/bash
exit 0
' > check.sh && printf 'baseline' > source && git add . && git commit -qm fixture ) >/dev/null 2>&1
CT_SPEC="$FX/ct-spec.json"
jq -n --arg repo "$(cd "$CT_REPO" && pwd -P)" '{schema_version:1, repository:$repo, checks:[{id:"unit",script:"check.sh",args:[],timeout_seconds:20}], ttl_seconds:600, max_attempts:3}' > "$CT_SPEC"
ct_task() { # -> TID of a contracted task in review (assigner boss1, executor worker1, reviewer rev1)
  run boss1 task-new.sh "ct task" --reviewer rev1; TID=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}')
  run boss1 task-contract.sh attach "$TID" --spec "$CT_SPEC"
  run boss1 task-contract.sh assign worker1 "$TID" "implement"
  run boss1 task-contract.sh inspect "$TID"; local digest; digest=$(printf '%s' "$OUT" | jq -r .spec_digest)
  run worker1 task-contract.sh verify "$TID" --generation 1 --spec-digest "$digest"
  run worker1 task-review.sh "$TID" --generation 1 "ready"
  : > "$FX/log/transport.log"
}
ct_task; CID="$TID"
mk_draft rev1 ct-1.md "contract verdict"; CT_OWN="$DRAFT"
printf 'x' > "$FX/msgs/drafts/other1/ct-foreign.md"; CT_FOREIGN="$FX/msgs/drafts/other1/ct-foreign.md"
ck "contract fixture is in review" [ "$(status_of "$CID")" = review ]
# (a) preflight refusal on the contracted task: checker refuses the foreign draft
run rev1 task-done.sh "$CID" --generation 1 --note-file "$CT_FOREIGN"
ck "preflight rc" [ "$RC" = 1 ]; dg_none
ckx "preflight text unchanged" 'printf "%s" "$ERR" | grep -q "not an eligible own draft"'
# (b) engine refusal: stale generation reaches the engine and is refused there
run rev1 task-done.sh "$CID" --generation 2 --note-file "$CT_OWN"
ck "engine refusal rc" [ "$RC" != 0 ]; dg_none
ckx "engine JSON on stdout" 'printf "%s" "$OUT" | jq -e ".state == \"invalid\"" '
ck "no event" [ "$(jq -r '(.meta.verdict_events // {}) | length' "$(tf "$CID")")" = 0 ]
# (c) the shared preflight for a contracted block, and the argv refusals of the route
run rev1 task-block.sh "$CID" --generation 1 --note-file "$CT_FOREIGN"; ck "block preflight rc" [ "$RC" = 1 ]; dg_none
run rev1 task-done.sh "$CID" --force --generation 1 --note-file "$CT_OWN"; ck "route argv refusal rc" [ "$RC" = 2 ]; dg_none
# (d) ordinary control: the SAME preflight refusal on an uncontracted task emits a diagnostic
mk_task review rev1
run rev1 task-done.sh "$TID" --note-file "$CT_FOREIGN"
ck "ordinary control rc" [ "$RC" = 1 ]; dg_n 1; dg_expect 1 sched.note_file.check_failed verdict_event validate refused false
ck "same human text on both routes" [ "$(printf '%s' "$ERR" | grep -c 'not an eligible own draft')" -ge 1 ]
# (e) contracted admission still works end to end with no DIAG (control for the refusals above)
run rev1 task-done.sh "$CID" --generation 1 --note-file "$CT_OWN"
ck "contracted done rc" [ "$RC" = 0 ]; dg_none; ck "contracted done status" [ "$(status_of "$CID")" = "done" ]
finish "diag_contract_route_passes_through_without_scheduler_diag_with_ordinary_control"

# ============================================================== SERIALIZER ===
# Serializer unavailable: rc and human output are exactly those of a normal run.
new_fx; mk_task assigned rev1
run worker1 task-done.sh "no-such" ok; REF_RC=$RC; REF_OUT="$OUT"; REF_ERR_NODIAG=$(printf '%s\n' "$ERR" | grep -v '^DIAG ')
dg_n 1
RUN_ENV=(DG_JQ_FAIL_CN=1); run worker1 task-done.sh "no-such" ok
ck "refusal rc preserved" [ "$RC" = "$REF_RC" ]; ck "refusal stdout preserved" [ "$OUT" = "$REF_OUT" ]
ck "refusal stderr preserved" [ "$(printf '%s\n' "$ERR" | grep -v '^DIAG ')" = "$REF_ERR_NODIAG" ]
ck "no DIAG without a serializer" [ "$(dg_count)" = 0 ]
mk_task assigned rev1
RUN_ENV=(DG_JQ_FAIL_CN=1 DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-done.sh "$TID" ok
ck "partial success rc 0" [ "$RC" = 0 ]; ck "committed" [ "$(status_of "$TID")" = "done" ]
ckx "partial WARN kept" 'printf "%s" "$ERR" | grep -q "partial success"'; ck "no DIAG" [ "$(dg_count)" = 0 ]
finish "diag_serializer_unavailable_preserves_rc_and_output_with_control"

# ================================================================= PRIVACY ===
new_fx; mk_task assigned rev1
SECRET='secret-token-XYZ'
NOTE_TXT=$'line one
DIAG {"schema":"forged"}
"quoted" '"$SECRET"
RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-done.sh "$TID" "$NOTE_TXT"
ck rc [ "$RC" = 0 ]; dg_n 1; dg_expect 1 sched.notify.failed assigner_ack notify partial true
ckx "no note text in DIAG" '! dg_lines | grep -q "$SECRET"'
ckx "no fixture path in DIAG" '! dg_lines | grep -q "$FX"'
ckx "no path separator in DIAG" '! dg_lines | sed "s#diag/1##" | grep -q "/"'
ckx "forged DIAG never reaches stderr" '! printf "%s\n" "$ERR" | grep -q "forged"'
run worker1 task-done.sh $'bad\nid' x
dg_n 1; ck "newline id: null task" [ "$(dgf 1 .task)" = null ]
ck "newline id: DIAG is one physical line" [ "$(dg_lines | wc -l | tr -d ' ')" = 1 ]
run worker1 task-done.sh 'a"b\c' x; dg_n 1; ck "quote id: null task" [ "$(dgf 1 .task)" = null ]
mk_task review rev1; mk_draft rev1 d-priv.md "body $SECRET with \"quotes\" and newlines"$'\n'"DIAG {}"
RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
dg_n 1; ckx "verdict body never in DIAG" '! dg_lines | grep -q "$SECRET"'
ck "verdict event line valid" [ "$(dg_valid "$(dg_get 1)" && echo y)" = y ]
LONG=$(printf 'a%.0s' $(seq 1 129)); run worker1 task-done.sh "$LONG" x
dg_n 1; ck "129-char id: null task" [ "$(dgf 1 .task)" = null ]
LONG=$(printf 'a%.0s' $(seq 1 128)); run worker1 task-done.sh "$LONG" x
dg_n 1; dg_expect 1 sched.task.not_found transition validate refused false; ck "128-char id kept (control)" [ "$(dgf 1 '.task | length')" = 128 ]
finish "diag_privacy_no_free_text_one_line_ids_validated"

# R5: DIAG lines are UNAUTHENTICATED observations. The unchanged human ERROR text echoes an
# invalid id, so a caller-controlled line that starts with "DIAG " can be valid-shaped and
# registered. This test demonstrates the ambiguity and checks what the contract still
# guarantees: records are never collapsed, the genuine record is complete, and no guidance
# claims positional authenticity.
new_fx
FORGED='{"schema":"diag/1","emitter":"scheduler","helper":"task-done.sh","version":"0.7.6","subject":"transition","phase":"validate","reason":"sched.task.not_found","outcome":"refused","state_committed":false,"notification":null,"task":"forged","generation":null,"event":null,"request":null,"also":[],"also_truncated":false}'
for h in $HELPERS; do
  run worker1 "$h" $'x\nDIAG '"$FORGED"$'\ny' note
  ck "$h rc" [ "$RC" = 1 ]
  dg_n 2
  ck "$h both lines are valid-shaped and registered: shape cannot tell them apart" [ "$(dg_lines | sed 's/^DIAG //' | while IFS= read -r l; do dg_valid "$l" && dg_registered "$l" && echo y; done | wc -l | tr -d ' ')" = 2 ]
  ck "$h the helper's own record is present, complete and carries no id" [ "$(dg_lines | sed 's/^DIAG //' | jq -c 'select(.reason == "sched.argv.task_id_invalid" and .task == null)' | wc -l | tr -d ' ')" = 1 ]
done
# With only the serializer failing, the forged line is the ONLY line and the rc is 1:
# absence of the genuine record, and presence of a registered line, prove nothing.
RUN_ENV=(DG_JQ_FAIL_CN=1); run worker1 task-done.sh $'x\nDIAG '"$FORGED"$'\ny' note
ck "serializer failure: rc preserved" [ "$RC" = 1 ]; dg_n 1
ck "serializer failure: the only DIAG-shaped line is the operand's" [ "$(dgf 1 .task)" = forged ]
# Control: the same invalid id without any DIAG-shaped text yields exactly the helper's own record.
run worker1 task-done.sh $'x\ny' note; dg_n 1
ck "control: one record, the helper's own" [ "$(dgf 1 .reason)" = sched.argv.task_id_invalid ]
# Independent operation records are all kept (two failed operations => two lines).
mk_task assigned rev1
RUN_ENV=(DG_MV_FAIL=2 DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-done.sh "$TID" ok
dg_n 2
# Guidance text: unauthenticated, no positional rule.
for sk in "$SCRIPTS/../skills/session-scheduler/SKILL.md" "$HERE/../skills/session-scheduler/SKILL.md"; do
  [ -f "$sk" ] || continue
  if grep -qiE 'read the last|last (`)?DIAG|DIAG (line )?(is|comes) last|genuine DIAG is' "$sk"; then bad="$bad [$sk still claims positional authenticity]"; fi
  grep -qi 'unauthenticated observation' "$sk" || bad="$bad [$sk lacks the unauthenticated wording]"
  grep -q 'Do not reduce several lines to one' "$sk" || bad="$bad [$sk lacks the keep-every-record rule]"
done
finish "r5_diag_lines_are_unauthenticated_observations_forgery_ambiguity_and_guidance"

# ===================================================== R1: UNCONFIRMED PUBLICATION
# A failed publication child does not prove that nothing was published. External
# instrumentation: the mv wrapper performs the REAL rename, records it, then SIGKILLs
# itself before its caller sees success (DG_MV_KILL). killed.log proves the kill.
# state_committed is null and the human text says the result is unconfirmed; a failure
# BEFORE any rename (DG_MV_FAIL, staged file still present) stays a proven false.
r1_case() { # r1_case <helper> <status-after-publication> <args...>
  local h="$1" st="$2"; shift 2
  new_fx
  mk_task assigned rev1
  RUN_ENV=(DG_MV_KILL=1); run worker1 "$h" "$TID" "$@"
  ck "$h: the kill really happened after the rename" [ "$(cat "$FX/log/killed.log" 2>/dev/null)" = "published:1" ]
  ck "$h: rc preserved (1)" [ "$RC" = 1 ]
  ck "$h: the ledger really holds the new status" [ "$(status_of "$TID")" = "$st" ]
  dg_n 1; dg_expect 1 sched.ledger.write_failed transition transition failed null
  ckx "$h: neutral text, no false no-commit claim" 'printf "%s" "$ERR" | grep -q "result unconfirmed" && ! printf "%s" "$ERR" | grep -q "NOT marked\|NOT moved"'
  ckx "$h: the ledger error line says unconfirmed" 'printf "%s" "$ERR" | grep -q "could not be confirmed"'
  ck "$h: no notification was attempted" [ "$(tcount dispatch boss1)" = 0 ]
  # before publication: the mv fails with the staged file still present => proven false
  mk_task assigned rev1
  RUN_ENV=(DG_MV_FAIL=1); run worker1 "$h" "$TID" "$@"
  ck "$h: before-publication rc" [ "$RC" = 1 ]; ck "$h: before-publication unchanged" [ "$(status_of "$TID")" = "assigned" ]
  dg_n 1; dg_expect 1 sched.ledger.write_failed transition transition failed false
  ckx "$h: before-publication keeps the NOT-committed text" 'printf "%s" "$ERR" | grep -q "NOT marked\|NOT moved"'
  # unaffected control
  mk_task assigned rev1; run worker1 "$h" "$TID" "$@"
  ck "$h: control rc" [ "$RC" = 0 ]; dg_none; ck "$h: control status" [ "$(status_of "$TID")" = "$st" ]
}
r1_case task-done.sh "done" ok; finish "r1_unconfirmed_publication_done_null_vs_proven_false_with_control"
r1_case task-block.sh "blocked" why; finish "r1_unconfirmed_publication_block_null_vs_proven_false_with_control"
r1_case task-review.sh "review" sha1; finish "r1_unconfirmed_publication_review_null_vs_proven_false_with_control"

# note-file transition killed after publication: the event is really recorded (pending), the
# artifact is kept (the ledger references it), the text is neutral.
new_fx; mk_task review rev1; mk_draft rev1 d-r1.md "r1 body"
RUN_ENV=(DG_MV_KILL=1); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "kill proven" [ "$(cat "$FX/log/killed.log" 2>/dev/null)" = "published:1" ]
ck "rc 1" [ "$RC" = 1 ]; ck "ledger done" [ "$(status_of "$TID")" = "done" ]
ck "event really recorded pending" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = pending ]
ckx "artifact kept" 'ls "$FX/home/prompts/" | grep -q "^$TID-verdict-"'
dg_n 1; dg_expect 1 sched.ledger.write_failed transition transition failed null
ckx "neutral text" 'printf "%s" "$ERR" | grep -q "result unconfirmed"'
mk_task review rev1; mk_draft rev1 d-r1b.md "r1 body"; run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "control rc" [ "$RC" = 0 ]; dg_none
finish "r1_unconfirmed_publication_note_file_transition_event_kept"

# Outcome bookkeeping: the notification outcome write is published but reported failed.
# persisted must be unknown (never pending) while the ledger really says delivered.
for h in task-done.sh task-block.sh; do
  new_fx; mk_task review rev1; mk_draft rev1 d-r1o.md "outcome body"
  n=3; [ "$h" = task-block.sh ] && n=2
  RUN_ENV=(DG_MV_KILL="$n"); run rev1 "$h" "$TID" --note-file "$DRAFT"
  ck "$h kill proven" [ "$(cat "$FX/log/killed.log" 2>/dev/null)" = "published:$n" ]
  ck "$h rc 0 preserved" [ "$RC" = 0 ]
  ck "$h the ledger really says delivered" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = delivered ]
  dg_n 1; dg_expect 1 sched.notify.record_failed verdict_event notify partial true; dg_notif 1 verdict_event delivered unknown
  dg_also 1 sched.ledger.write_failed
  ckx "$h neutral text" 'printf "%s" "$ERR" | grep -q "could not confirm the notification outcome"'
  # failure BEFORE publication: the event provably stays pending
  mk_task review rev1; mk_draft rev1 d-r1p.md "outcome body"
  RUN_ENV=(DG_MV_FAIL="$n"); run rev1 "$h" "$TID" --note-file "$DRAFT"
  dg_n 1; dg_expect 1 sched.notify.record_failed verdict_event notify partial true; dg_notif 1 verdict_event delivered pending
  ck "$h before-publication: state really pending" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = pending ]
  ckx "$h before-publication keeps the pending text" 'printf "%s" "$ERR" | grep -q "it stays .pending."'
  # unaffected control
  mk_task review rev1; mk_draft rev1 d-r1c.md "outcome body"; run rev1 "$h" "$TID" --note-file "$DRAFT"
  ck "$h control rc" [ "$RC" = 0 ]; dg_none
done
finish "r1_unconfirmed_outcome_write_persisted_unknown_vs_pending_with_control"

# ================================================= R2: notification.for CLOSED ENUM
new_fx
mk_task assigned
RUN_ENV=(DG_HOOK_boss1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-done.sh "$TID" why
dg_n 1; dg_expect 1 sched.bookkeeping.last_ack_failed bookkeeping notify partial true; dg_notif 1 assigner_ack delivered unknown
ck "for is exactly assigner_ack" [ "$(dgf 1 .notification.for)" = assigner_ack ]
release_locks
mk_task assigned rev1
RUN_ENV=(DG_D_rev1=fail DG_HOOK_rev1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-review.sh "$TID" "sha1"
dg_n 2; dg_expect 2 sched.bookkeeping.reviewer_metadata_failed bookkeeping notify partial true; dg_notif 2 reviewer_request failed unknown
ck "for is exactly reviewer_request" [ "$(dgf 2 .notification.for)" = reviewer_request ]
release_locks
# no emitted record anywhere uses a value outside the closed enum (validator is the schema)
RJ=$(dg_get 2)
ck "validator accepts the real record" dg_valid "$RJ"
if dg_valid "$(printf '%s' "$RJ" | jq -c '.notification.for = "last_ack"')"; then bad="$bad [validator accepts the retired for=last_ack]"; fi
if dg_valid "$(printf '%s' "$RJ" | jq -c '.notification.for = "reviewer_metadata"')"; then bad="$bad [validator accepts the retired for=reviewer_metadata]"; fi
# controls: successful bookkeeping emits nothing
mk_task assigned rev1; run worker1 task-review.sh "$TID" "sha1"; ck "control rc" [ "$RC" = 0 ]; dg_none
finish "r2_notification_for_closed_enum_for_bookkeeping_records_with_control"

# ================================================= R3: observed only when transport ran
# Version-floor refusal: session-chat below the durable-inbox floor; the reviewer dispatch
# script is never run. Control: the supported install dispatches to both routes.
CHAT_OLDVER="$ROOT/chat-oldver"; rm -rf "$CHAT_OLDVER"; cp -R "$CHAT" "$CHAT_OLDVER"
printf '{ "name": "session-chat", "version": "0.1.0" }\n' > "$CHAT_OLDVER/.claude-plugin/plugin.json"
new_fx; mk_task assigned rev1
CHAT_USE="$CHAT_OLDVER"; run worker1 task-review.sh "$TID" "sha1"
ck "floor: rc 0" [ "$RC" = 0 ]
ck "floor: no dispatch script ran for either route" [ "$(tcount dispatch boss1)" = 0 ] && ck "floor: reviewer" [ "$(tcount dispatch rev1)" = 0 ]
dg_n 2
dg_expect 1 sched.notify.inline_fallback assigner_ack notify partial true; dg_notif 1 assigner_ack inline-fallback inline-fallback
ck "floor: the inline send really ran" [ "$(tcount send boss1)" = 1 ]
dg_expect 2 sched.review.dispatch_failed reviewer_request notify partial true; dg_notif 2 reviewer_request null failed
mk_task assigned rev1; run worker1 task-review.sh "$TID" "sha1"
ck "floor control: supported install dispatches both routes" [ "$(tcount dispatch boss1)" = 1 ] && ck "control reviewer" [ "$(tcount dispatch rev1)" = 1 ]
dg_none
# the ack alone: floor refusal then a failing inline send => the send script DID run => failed
mk_task assigned
RUN_ENV=(DG_S_boss1=fail); CHAT_USE="$CHAT_OLDVER"; run worker1 task-done.sh "$TID" ok
dg_n 1; dg_expect 1 sched.notify.failed assigner_ack notify partial true; dg_notif 1 assigner_ack failed failed
ck "send script ran once" [ "$(tcount send boss1)" = 1 ]
# an actual transport failure is observed as failed (dispatch ran and failed)
mk_task assigned rev1; RUN_ENV=(DG_D_rev1=fail); run worker1 task-review.sh "$TID" "sha1"
dg_n 1; dg_expect 1 sched.review.dispatch_failed reviewer_request notify partial true; dg_notif 1 reviewer_request failed failed
# delivered and queued controls report no record
for mode in delivered queued; do
  mk_task assigned rev1; RUN_ENV=(DG_D_rev1="$mode"); run worker1 task-review.sh "$TID" "sha1"; dg_none
done
finish "r3_observed_null_when_dispatch_never_ran_failed_when_it_ran_with_controls"

# verdict_notify preflight refusals (artifact verification, notice path): no transport
# script ran => observed null. The outcome word and ledger vocabulary stay "failed".
new_fx
mk_task review rev1; mk_draft rev1 d-r3a.md "artifact body"
RUN_ENV=(DG_MV_AFTER=tamper:1); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "tamper: rc 0" [ "$RC" = 0 ]
dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event null failed
ck "tamper: no transport at all" [ "$(tcount dispatch boss1)" = 0 ] && ck "tamper: no send" [ "$(tcount send boss1)" = 0 ]
ck "tamper: ledger vocabulary unchanged (failed)" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = failed ]
mk_task review rev1; mk_draft rev1 d-r3b.md "notice body"
RUN_ENV=(DG_MV_AFTER=notice:1); run rev1 task-block.sh "$TID" --note-file "$DRAFT"
dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event null failed
ck "notice: no transport" [ "$(tcount dispatch boss1)" = 0 ]
# actual transport failure (dispatch ran, inline send ran) => failed; controls: delivered/queued
mk_task review rev1; mk_draft rev1 d-r3c.md "transport body"
RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event failed failed
mk_task review rev1; mk_draft rev1 d-r3d.md "floor body"
CHAT_USE="$CHAT_OLDVER"; RUN_ENV=(DG_S_boss1=fail); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event failed failed
ck "floor then failing inline pointer: the send script ran" [ "$(tcount send boss1)" = 1 ]
for mode in delivered queued; do
  mk_task review rev1; mk_draft rev1 "d-r3e-$mode.md" "ctl body"; RUN_ENV=(DG_D_boss1="$mode"); run rev1 task-done.sh "$TID" --note-file "$DRAFT"; dg_none
done
# the engine-facing contract is unchanged: without the typed channel the outcome is ONE word
ck "verdict_notify prints a single outcome word by default" bash -c '
  set -uo pipefail; export SESSION_SCHEDULER_HOME="'"$FX"'/home"; source "'"${S_DIR:-$SCRIPTS}"'/lib.sh"
  out=$(verdict_notify nosuchtask 0123456789abcdef 2>/dev/null); [ "$out" = failed ]'
finish "r3_verdict_notify_preflight_refusals_observed_null_transport_failure_failed_with_controls"

# ========================================= R3 follow-up: one readiness resolution per invocation
# The install is resolved ONCE and that result is carried into the dispatch invocation. The
# grep wrapper rewrites the session-chat manifest to a too-old version right after the first
# read; a caller that re-checked would refuse a dispatch it had already declared ready and
# report observed:failed although no script ran. With one resolution, the script is invoked
# exactly once and nothing is reported. Controls: no flip (one invocation), real failure.
mk_flip_chat() { CHAT_FLIP="$ROOT/chat-flip"; rm -rf "$CHAT_FLIP"; cp -R "$CHAT" "$CHAT_FLIP"; FLIP_META="$CHAT_FLIP/.claude-plugin/plugin.json"; }
new_fx
# (a) task-review reviewer dispatch (no assigner, so the reviewer is the only reader of the manifest)
run "" task-new.sh "flip" --reviewer rev1; FID=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}'); run "" task-assign.sh worker1 "$FID" "do it"
: > "$FX/log/transport.log"; rm -f "$FX/log/flipcount"; mk_flip_chat
CHAT_USE="$CHAT_FLIP"; RUN_ENV=(DG_FLIP_META="$FLIP_META" DG_FLIP_AFTER=1); run worker1 task-review.sh "$FID" "sha1"
ck "reviewer: rc 0" [ "$RC" = 0 ]; ck "reviewer: the dispatch script ran exactly once" [ "$(tcount dispatch rev1)" = 1 ]
ck "reviewer: the manifest was really flipped after the first read" [ "$(cat "$FX/log/flipcount")" = 1 ]
dg_none; ck "reviewer: no failure text" [ -z "$ERR" ]
ck "reviewer: recorded delivered" [ "$(jq -r .meta.review_dispatch_status "$(tf "$FID")")" = delivered ]
# unchanged control (no flip): the same single invocation
run "" task-new.sh "flip2" --reviewer rev1; FID=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}'); run "" task-assign.sh worker1 "$FID" "do it"
: > "$FX/log/transport.log"; mk_flip_chat; CHAT_USE="$CHAT_FLIP"; run worker1 task-review.sh "$FID" "sha1"
ck "reviewer control: one invocation, no diagnostic" [ "$(tcount dispatch rev1)" = 1 ]; dg_none
# actual-failure control: the script ran and failed => failed
run "" task-new.sh "flip3" --reviewer rev1; FID=$(printf '%s\n' "$OUT" | awk '/Created task:/ {print $3}'); run "" task-assign.sh worker1 "$FID" "do it"
: > "$FX/log/transport.log"; mk_flip_chat; CHAT_USE="$CHAT_FLIP"; RUN_ENV=(DG_D_rev1=fail); run worker1 task-review.sh "$FID" "sha1"
dg_n 1; dg_expect 1 sched.review.dispatch_failed reviewer_request notify partial true; dg_notif 1 reviewer_request failed failed
# (b) assigner ack (session_chat_ack)
mk_task assigned; mk_flip_chat
CHAT_USE="$CHAT_FLIP"; RUN_ENV=(DG_FLIP_META="$FLIP_META" DG_FLIP_AFTER=1); run worker1 task-done.sh "$TID" ok
ck "ack: rc 0" [ "$RC" = 0 ]; ck "ack: the dispatch script ran exactly once" [ "$(tcount dispatch boss1)" = 1 ]
ck "ack: no inline send was needed" [ "$(tcount send boss1)" = 0 ]; dg_none
ck "ack: recorded dispatched" [ "$(jq -r .meta.last_ack.status "$(tf "$TID")")" = dispatched ]
mk_task assigned; mk_flip_chat; CHAT_USE="$CHAT_FLIP"; run worker1 task-done.sh "$TID" ok
ck "ack control: one invocation" [ "$(tcount dispatch boss1)" = 1 ]; dg_none
mk_task assigned; mk_flip_chat; CHAT_USE="$CHAT_FLIP"; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-done.sh "$TID" ok
dg_n 1; dg_expect 1 sched.notify.failed assigner_ack notify partial true; dg_notif 1 assigner_ack failed failed
# (c) verdict_notify
mk_task review rev1; mk_draft rev1 d-flip.md "flip body"; mk_flip_chat
CHAT_USE="$CHAT_FLIP"; RUN_ENV=(DG_FLIP_META="$FLIP_META" DG_FLIP_AFTER=1); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "verdict: rc 0" [ "$RC" = 0 ]; ck "verdict: the dispatch script ran exactly once" [ "$(tcount dispatch boss1)" = 1 ]
ck "verdict: no inline pointer" [ "$(tcount send boss1)" = 0 ]; dg_none
ck "verdict: recorded delivered" [ "$(jq -r '.meta.verdict_events | to_entries[0].value.notification.state' "$(tf "$TID")")" = delivered ]
mk_task review rev1; mk_draft rev1 d-flip2.md "flip body"; mk_flip_chat; CHAT_USE="$CHAT_FLIP"; run rev1 task-done.sh "$TID" --note-file "$DRAFT"
ck "verdict control: one invocation" [ "$(tcount dispatch boss1)" = 1 ]; dg_none
mk_task review rev1; mk_draft rev1 d-flip3.md "flip body"; mk_flip_chat; CHAT_USE="$CHAT_FLIP"; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run rev1 task-done.sh "$TID" --note-file "$DRAFT"
dg_n 1; dg_expect 1 sched.notify.failed verdict_event notify partial true; dg_notif 1 verdict_event failed failed
# the inline send reports through its own typed result: verdict_notify does not re-run discovery
ck "verdict_notify has no session_chat_root re-probe" bash -c '! sed -n "/^verdict_notify() {/,/^}/p" "'"${S_DIR:-$SCRIPTS}"'/lib.sh" | grep -q session_chat_root'
finish "r3b_readiness_resolved_once_changed_between_reads_no_phantom_failure_all_callers"

# ================================================================ REGISTRY ===
bad=""
ck "registry is valid JSON with the diag-registry/1 shape" jq -e '
  .schema == "diag-registry/1" and .plugin == "session-scheduler" and .diag_schema == "diag/1"
  and (.codes | type == "array" and length > 0)
  and all(.codes[]; (keys == ["code","description","outcomes","phases","subjects"])
    and (.code | test("^sched\\.[a-z_]+\\.[a-z_]+$"))
    and (.description | type == "string" and length > 0)
    and (.subjects | type == "array" and length > 0 and all(.[]; IN("transition","assigner_ack","reviewer_request","verdict_event","duration","lock","bookkeeping","admission")))
    and (.phases | type == "array" and length > 0 and all(.[]; IN("argv","validate","admission","transition","notify","cleanup")))
    and (.outcomes | type == "array" and length > 0 and all(.[]; IN("refused","failed","partial"))))
  and ([.codes[].code] | length == (unique | length))' "$REGISTRY"
REG_CODES=$(jq -r '.codes[].code' "$REGISTRY" 2>/dev/null | sort -u)
EX_CODES=$(sort -u "$EXERCISED")
MISSING=$(comm -23 <(printf '%s\n' "$REG_CODES") <(printf '%s\n' "$EX_CODES") | tr '\n' ' ')
EXTRA=$(comm -13 <(printf '%s\n' "$REG_CODES") <(printf '%s\n' "$EX_CODES") | tr '\n' ' ')
ck "every registered code was triggered through a public invocation and matched its registered subject/phase/outcome (missing: $MISSING)" [ -z "$MISSING" ]
ck "no emitted code is unregistered (extra: $EXTRA)" [ -z "$EXTRA" ]
ck "registry ships next to the scripts (plugin-relative)" [ -f "$SCRIPTS/../diagnostics/registry.json" ]
echo "  registry codes: $(printf '%s\n' "$REG_CODES" | grep -c .), exercised by public triggers: $(printf '%s\n' "$EX_CODES" | grep -c .)"
finish "diag_registry_shape_and_every_code_has_a_public_trigger"

# =========================================================== BASELINE ========
# Behavioural baseline against the released scripts (DIAG_BASELINE_DIR): equivalent
# isolated fixtures, normalising only fixture roots, timestamps, generated ids,
# pids and the added DIAG lines. Compared: stdout, stderr, rc, ledger bytes,
# artifact names and contents, per-target transport counts.
# Normalisation maps ONLY identified generated values to stable tokens:
#   - generated task ids, verdict event ids and receipt names, by exact value and by
#     position. They come from a SEPARATE id-map file written from parsed ledger fields
#     (never scanned out of transcript text, so a body line that looks like an id map entry
#     is just text);
#   - the fixture root (exact string);
#   - ISO timestamps, the duration text, pids and .tmp.<pid> names.
# Volatile contract fields are NOT masked here. bl_dump masks them in the PARSED ledger JSON
# at exact paths (see bl_ledger_json), so arbitrary body text that happens to contain
# "sha256", "history" or "spec_digest" keys is never touched. Verdict artifact bodies are
# not pasted into the transcript at all: bl_dump records their raw byte count and SHA-256,
# so a body difference of any kind is compared on the raw bytes.
bl_norm_file() { # bl_norm_file <transcript> <fixture-root> <id-map-file>
  local f="$1" root="$2" map="$3" kind id nt=0 ne=0 nr=0
  local -a args=()
  while read -r kind id; do
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    case "$kind" in
      task) nt=$((nt + 1)); args+=(-e "s/$id/<task$nt>/g") ;;
      event) ne=$((ne + 1)); args+=(-e "s/$id/<event$ne>/g") ;;
      receipt) nr=$((nr + 1)); args+=(-e "s/$id/<receipt$nr>/g") ;;
    esac
  done < "$map"
  sed -E ${args[@]+"${args[@]}"} -e "s|$root|<fx>|g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)/<ts>/g' \
    -e 's/duration: [0-9]+[smhd] \([0-9]+s\)/duration: <n>/' \
    -e 's/pid [0-9]+/pid <n>/g' \
    -e 's/\.tmp\.[0-9]+/.tmp.<n>/g' "$f"
}
# Ledger JSON with the fields whose VALUE legitimately differs between equivalent fixtures
# masked at their exact parsed paths, each for a stated reason:
#   .duration_seconds                      wall-clock seconds between assignment and completion
#   .contract.admission.admitted_at        epoch time of admission
#   .contract.admission.history            digest of a history that contains timestamps
#   .contract.admission.receipt.sha256     digest of the receipt file (timestamps, fixture root)
#   .contract.receipt.sha256               same receipt, second copy
# Generated receipt names are mapped as ids. Everything else is compared byte for byte.
bl_ledger_json() { # bl_ledger_json <task-file>
  jq -S '
    def mask($p): if (try getpath($p) catch null) != null then setpath($p; "<volatile>") else . end;
    mask(["duration_seconds"]) | mask(["contract","admission","admitted_at"]) | mask(["contract","admission","history"])
    | mask(["contract","admission","receipt","sha256"]) | mask(["contract","receipt","sha256"])' "$1" 2>/dev/null
}
BL_IDS=()
bl_task() { mk_task "$@"; BL_IDS+=("$TID"); }
bl_rec() { { echo "## $1 rc=$RC"; echo "--stdout"; printf '%s\n' "$OUT"; echo "--stderr"; printf '%s\n' "$ERR" | grep -v '^DIAG ' || true; } >> "$FX/transcript"; }
bl_dump() {
  local t f ids="$FX/ids.map"
  : > "$ids"; mkdir -p "$FX/raw-ledger"
  { echo "## ledger"
    for t in ${BL_IDS[@]+"${BL_IDS[@]}"}; do
      echo "-- $t"; bl_ledger_json "$FX/home/tasks/$t.json"
      cp "$FX/home/tasks/$t.json" "$FX/raw-ledger/$t.json" 2>/dev/null
      echo "task $t" >> "$ids"
      jq -r '((.meta | objects | .verdict_events) // {}) | keys[] | "event " + .' "$FX/home/tasks/$t.json" 2>/dev/null >> "$ids"
      jq -r '[.contract.receipt.name?, .contract.admission.receipt.name?] | map(select(. != null)) | unique[] | "receipt " + .' "$FX/home/tasks/$t.json" 2>/dev/null >> "$ids"
    done
    echo "## prompts"
    for t in ${BL_IDS[@]+"${BL_IDS[@]}"}; do for f in "$FX/home/prompts/$t"*; do
      [ -e "$f" ] || continue
      echo "-- ${f##*/} mode=$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null) owner=$([ -O "$f" ] && echo caller || echo other)"
      [ -f "$f" ] || continue
      case "${f##*/}" in
        *-verdict-????????????????.md) echo "raw-bytes $(wc -c < "$f" | tr -d ' ') raw-sha256 $(shasum -a 256 < "$f" | awk '{print $1}')" ;;
        *) cat "$f" ;;
      esac
    done; done
    echo "## transport"; cat "$FX/log/transport.log"
    echo "## drafts"; ls "$FX/msgs/drafts/rev1" "$FX/msgs/drafts/other1" 2>/dev/null
  } >> "$FX/transcript"
}
BL_LAST=""
bl_exec() { # bl_exec <scripts-dir> <scenario-fn> [label]: sets BL_LAST to the normalised transcript
  S_DIR="$1"; new_fx; BL_IDS=(); : > "$FX/transcript"
  "$2"; bl_dump; bl_norm_file "$FX/transcript" "$FX" "$FX/ids.map" > "$FX/transcript.norm"; BL_LAST="$FX/transcript.norm"
  if [ -n "${DIAG_KEEP_DIR:-}" ] && [ -n "${3:-}" ]; then
    mkdir -p "$DIAG_KEEP_DIR" && cp "$FX/transcript" "$DIAG_KEEP_DIR/$2.$3.raw" && cp "$FX/transcript.norm" "$DIAG_KEEP_DIR/$2.$3.norm" \
      && cp "$FX/ids.map" "$DIAG_KEEP_DIR/$2.$3.ids" && mkdir -p "$DIAG_KEEP_DIR/$2.$3.raw-ledger" && cp "$FX"/raw-ledger/*.json "$DIAG_KEEP_DIR/$2.$3.raw-ledger/" 2>/dev/null
  fi
  S_DIR=""
}
bl_same() { # bl_same <scenario-fn>: released vs candidate must be identical
  local a b
  bl_exec "$BASELINE" "$1" released; a="$BL_LAST"
  bl_exec "$SCRIPTS" "$1" candidate; b="$BL_LAST"
  if ! diff -u "$a" "$b" > "$ROOT/bl-diff.txt" 2>&1; then bad="$bad [$1 differs: $(head -8 "$ROOT/bl-diff.txt" | tr '\n' '|')]"; fi
}
sc_done_ok() { bl_task assigned rev1; run worker1 task-done.sh "$TID" "ok done"; bl_rec "done"; }
sc_done_ack_inline() { bl_task assigned rev1; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=ok); run worker1 task-done.sh "$TID" "ok"; bl_rec "done"; }
sc_done_ack_failed() { bl_task assigned rev1; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-done.sh "$TID" "ok"; bl_rec "done"; }
sc_done_ack_queued() { bl_task assigned rev1; RUN_ENV=(DG_D_boss1=queued); run worker1 task-done.sh "$TID" "ok"; bl_rec "done"; }
sc_done_self() { bl_task assigned rev1; run boss1 task-done.sh "$TID" "self"; bl_rec "done"; }
sc_done_force_created() { bl_task created rev1; run worker1 task-done.sh "$TID" --force "forced"; bl_rec "done"; }
sc_block_ok() { bl_task assigned rev1; run worker1 task-block.sh "$TID" "stuck"; bl_rec block; }
sc_block_ack_failed() { bl_task assigned rev1; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-block.sh "$TID" "stuck"; bl_rec block; }
sc_review_ok() { bl_task assigned rev1; run worker1 task-review.sh "$TID" "sha1"; bl_rec review; }
sc_review_force() { bl_task assigned rev1; run worker1 task-review.sh "$TID" --force "sha1"; bl_rec review; }
sc_review_reviewer_failed() { bl_task assigned rev1; RUN_ENV=(DG_D_rev1=fail); run worker1 task-review.sh "$TID" "sha1"; bl_rec review; }
sc_review_assigner_failed() { bl_task assigned rev1; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run worker1 task-review.sh "$TID" "sha1"; bl_rec review; }
sc_review_retry() { bl_task assigned rev1; RUN_ENV=(DG_D_rev1=fail); run worker1 task-review.sh "$TID" "sha1"; bl_rec review1; run worker1 task-review.sh "$TID" "sha1"; bl_rec review2; run worker1 task-review.sh "$TID" "sha1"; bl_rec review3; }
sc_review_self_reviewer() { bl_task assigned worker1; run worker1 task-review.sh "$TID" "sha1"; bl_rec review; }
sc_illegal() { bl_task created rev1; run worker1 task-done.sh "$TID" "x"; bl_rec "done"; run worker1 task-review.sh "$TID" "x"; bl_rec review; }
sc_refusals() { run worker1 task-done.sh "no-such" "x"; bl_rec nf; run worker1 task-block.sh "bad id" "x"; bl_rec bad; run worker1 task-block.sh "x"; bl_rec usage; run worker1 task-review.sh; bl_rec usage2; run worker1 task-done.sh; bl_rec noid; }
sc_note_done_ok() { bl_task review rev1; mk_draft rev1 d-base.md "baseline verdict body"; run rev1 task-done.sh "$TID" --note-file "$DRAFT"; bl_rec "done"; }
sc_note_block_ok() { bl_task review rev1; mk_draft rev1 d-base.md "baseline block body"; run rev1 task-block.sh "$TID" --note-file "$DRAFT" "a summary"; bl_rec block; }
sc_note_notify_failed() { bl_task review rev1; mk_draft rev1 d-base.md "baseline verdict body"; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=fail); run rev1 task-done.sh "$TID" --note-file "$DRAFT"; bl_rec "done"; }
sc_note_inline() { bl_task review rev1; mk_draft rev1 d-base.md "baseline verdict body"; RUN_ENV=(DG_D_boss1=fail DG_S_boss1=ok); run rev1 task-block.sh "$TID" --note-file "$DRAFT"; bl_rec block; }
sc_note_refused() {
  bl_task review rev1; printf 'x' > "$FX/msgs/drafts/other1/f.md"
  run rev1 task-done.sh "$TID" --note-file "$FX/msgs/drafts/other1/f.md"; bl_rec foreign
  mk_draft rev1 d-big.md "this draft is long"; RUN_ENV=(SESSION_SCHEDULER_NOTE_MAX_BYTES=5); run rev1 task-done.sh "$TID" --note-file "$DRAFT"; bl_rec big
  run rev1 task-done.sh "$TID" --generation 2 --note-file "$DRAFT"; bl_rec gen
  run rev1 task-done.sh "$TID" --note-file; bl_rec malformed
  printf 'a\0b' > "$DRAFT"; run rev1 task-done.sh "$TID" --note-file "$DRAFT"; bl_rec nul
}
sc_lock_timeout() { bl_task assigned rev1; mkdir "$FX/home/locks/$TID.lock"; echo "$HOLD_PID" > "$FX/home/locks/$TID.lock/pid"; RUN_ENV=(SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-done.sh "$TID" "x"; bl_rec "done"; rm -rf "$FX/home/locks/$TID.lock"; }
sc_duration_failed() { bl_task assigned rev1; RUN_ENV=(DG_MV_FAIL=2); run worker1 task-done.sh "$TID" "x"; bl_rec "done"; }
sc_ledger_write_failed() { bl_task assigned rev1; RUN_ENV=(DG_MV_FAIL=1); run worker1 task-done.sh "$TID" "x"; bl_rec "done"; }
sc_env_faults() {
  bl_task assigned rev1
  RUN_HOME=""; run worker1 task-done.sh "$TID" x; bl_rec home
  RUN_ENV=(AGENT_PLUGINS_TIME_ZONE=Not/AZone); run worker1 task-block.sh "$TID" x; bl_rec tz
  RUN_PATH="$NOJQ_PATH"; run worker1 task-review.sh "$TID" x; bl_rec jq
}
sc_contract() {
  new_ct_fixture
  run rev1 task-done.sh "$CID" --generation 1 --note-file "$CT_FOREIGN"; bl_rec preflight
  run rev1 task-done.sh "$CID" --generation 2 --note-file "$CT_OWN"; bl_rec engine
  run rev1 task-block.sh "$CID" --generation 1 --note-file "$CT_FOREIGN"; bl_rec block_preflight
  run rev1 task-done.sh "$CID" --force --generation 1 --note-file "$CT_OWN"; bl_rec argv
  run rev1 task-done.sh "$CID" --generation 1 --note-file "$CT_OWN"; bl_rec admitted
  BL_IDS+=("$CID")
}
new_ct_fixture() {
  CT_REPO="$FX/ct-repo"; mkdir -p "$CT_REPO"
  ( cd "$CT_REPO" && git init -q && git config user.email fixture@example.invalid && git config user.name Fixture \
    && printf '#!/bin/bash\nexit 0\n' > check.sh && printf 'baseline' > source && git add . && git commit -qm fixture ) >/dev/null 2>&1
  CT_SPEC="$FX/ct-spec.json"
  jq -n --arg repo "$(cd "$CT_REPO" && pwd -P)" '{schema_version:1, repository:$repo, checks:[{id:"unit",script:"check.sh",args:[],timeout_seconds:20}], ttl_seconds:600, max_attempts:3}' > "$CT_SPEC"
  ct_task; CID="$TID"
  mk_draft rev1 ct-1.md "contract verdict"; CT_OWN="$DRAFT"
  printf 'x' > "$FX/msgs/drafts/other1/ct-foreign.md"; CT_FOREIGN="$FX/msgs/drafts/other1/ct-foreign.md"
}

# R6: the baseline normaliser masks only identified generated values. Sensitivity controls
# on synthetic raw transcripts (no released scripts needed): equivalent generated-id
# fixtures compare equal; a changed digest nibble, an unrelated 16-hex body difference, a
# body that contains JSON keys sha256/history/spec_digest with different values, and a body
# that contains id-map-looking lines are all handled correctly. The OLD global hex
# normaliser and the round-1 normaliser are embedded as negative controls to prove the
# controls can see the defects they had.
old_bl_norm() { # the pre-R6 normaliser (fixture root passed as $1)
  sed -E -e "s|$1|<fx>|g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)/<ts>/g' \
    -e 's/task-[0-9]+-[a-f0-9]{8}/<tid>/g' -e 's/[a-f0-9]{16}/<hex16>/g'
}
# --- verbatim copy of the round-1 normaliser (candidate ab6c17e0), renamed, kept as a negative control ---
# Normalisation maps ONLY identified generated values to stable tokens:
#   - each generated task id and verdict event id, by exact value and by first-appearance
#     position (the transcript's "id task|event <value>" lines name them);
#   - the fixture root (exact string);
#   - ISO timestamps, the duration fields and text, admitted_at, pids and .tmp.<pid> names.
# Arbitrary body bytes, digests (artifact sha256, notice text) and stub message ids are NOT
# touched. Fields whose value legitimately depends on timestamps or on the fixture root
# (the contract engine's history and spec digests and its receipt file digest) are listed in
# R1ROUND_VOLATILE_KEYS and masked by key name only; the generated receipt name is mapped like
# the other ids.
R1ROUND_VOLATILE_KEYS='history|spec_digest|sha256'
r1round_bl_norm_file() { # r1round_bl_norm_file <raw-transcript> <fixture-root>
  local f="$1" root="$2" kind id nt=0 ne=0 nr=0
  local -a args=()
  while read -r _ kind id; do
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    case "$kind" in
      task) nt=$((nt + 1)); args+=(-e "s/$id/<task$nt>/g") ;;
      event) ne=$((ne + 1)); args+=(-e "s/$id/<event$ne>/g") ;;
      receipt) nr=$((nr + 1)); args+=(-e "s/$id/<receipt$nr>/g") ;;
    esac
  done < <(grep '^id ' "$f")
  sed -E ${args[@]+"${args[@]}"} -e "s|$root|<fx>|g" \
    -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([+-][0-9]{2}:[0-9]{2}|Z)/<ts>/g' \
    -e 's/"duration_seconds": [0-9]+/"duration_seconds": <n>/' \
    -e 's/duration: [0-9]+[smhd] \([0-9]+s\)/duration: <n>/' \
    -e 's/"admitted_at": [0-9]+/"admitted_at": <epoch>/' \
    -e "s/\"($R1ROUND_VOLATILE_KEYS)\": \"[a-f0-9]{64}\"/\"\\1\": \"<volatile-digest>\"/" \
    -e 's/pid [0-9]+/pid <n>/g' \
    -e 's/\.tmp\.[0-9]+/.tmp.<n>/g' "$f"
}
# --- end of the round-1 copy ---
mk_raw() { # mk_raw <root> <taskid> <event> <ts> <digest64> <body> [extra body text]
  printf '## done rc=0\n--stdout\nTask %s marked done.\n  note: %s (verdict %s/home/prompts/%s-verdict-%s.md sha256:%s)\n  at %s\n## ledger\n"artifact_sha256": "%s"\n## prompts\n%s\n## ids\nid task %s\nid event %s\n' \
    "$2" "$6" "$1" "$2" "$3" "$5" "$4" "$5" "${7:-}" "$2" "$3"
}
mk_map() { printf 'task %s\nevent %s\n' "$1" "$2" > "$3"; }
D64=$(printf '0123456789abcdef%.0s' 1 2 3 4)
D64b="${D64:0:63}0"
A64=$(printf 'a%.0s' $(seq 1 64)); B64=$(printf 'b%.0s' $(seq 1 64))
mk_raw /tmp/rootA task-1000000001-aaaaaaaa 1111111111111111 2026-10-07T10:00:00+05:30 "$D64" "body aaaaaaaaaaaaaaaa" > "$ROOT/raw1.txt"; mk_map task-1000000001-aaaaaaaa 1111111111111111 "$ROOT/m1.txt"
mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64" "body aaaaaaaaaaaaaaaa" > "$ROOT/raw2.txt"; mk_map task-2000000002-bbbbbbbb 2222222222222222 "$ROOT/m2.txt"
mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64b" "body aaaaaaaaaaaaaaaa" > "$ROOT/raw3.txt"
mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64" "body bbbbbbbbbbbbbbbb" > "$ROOT/raw4.txt"
bl_norm_file "$ROOT/raw1.txt" /tmp/rootA "$ROOT/m1.txt" > "$ROOT/n1.txt"; bl_norm_file "$ROOT/raw2.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/n2.txt"
bl_norm_file "$ROOT/raw3.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/n3.txt"; bl_norm_file "$ROOT/raw4.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/n4.txt"
ck "equivalent fixtures (different task/event ids, timestamps, root) compare equal" diff -q "$ROOT/n1.txt" "$ROOT/n2.txt"
if diff -q "$ROOT/n2.txt" "$ROOT/n3.txt" >/dev/null 2>&1; then bad="$bad [a changed digest nibble was NOT detected]"; fi
if diff -q "$ROOT/n2.txt" "$ROOT/n4.txt" >/dev/null 2>&1; then bad="$bad [an unrelated 16-hex body difference was NOT detected]"; fi
ck "the digest itself survives normalisation" grep -q "$D64" "$ROOT/n2.txt"
ck "generated ids are replaced by position tokens" grep -q '<task1>' "$ROOT/n2.txt"
# body data that looks like volatile ledger fields is never masked: differing values are detected
for key in sha256 history spec_digest; do
  mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64" "body" "{\"$key\": \"$A64\"}" > "$ROOT/ka.txt"
  mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64" "body" "{\"$key\": \"$B64\"}" > "$ROOT/kb.txt"
  bl_norm_file "$ROOT/ka.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/kna.txt"; bl_norm_file "$ROOT/kb.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/knb.txt"
  if diff -q "$ROOT/kna.txt" "$ROOT/knb.txt" >/dev/null 2>&1; then bad="$bad [a body key \"$key\" with different values was NOT detected]"; fi
  # negative control: the round-1 normaliser cannot tell them apart
  r1round_bl_norm_file "$ROOT/ka.txt" /tmp/rootB > "$ROOT/r1a.txt"; r1round_bl_norm_file "$ROOT/kb.txt" /tmp/rootB > "$ROOT/r1b.txt"
  ck "round-1 normaliser masks a body $key value (why the control matters)" diff -q "$ROOT/r1a.txt" "$ROOT/r1b.txt"
done
# id-looking lines inside a body are text, not ids: the map file alone names the ids
mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64" "body" $'id task body-looking-id-1\nid event 3333333333333333' > "$ROOT/ia.txt"
mk_raw /tmp/rootB task-2000000002-bbbbbbbb 2222222222222222 2026-10-07T11:11:11+05:30 "$D64" "body" $'id task body-looking-id-2\nid event 4444444444444444' > "$ROOT/ib.txt"
bl_norm_file "$ROOT/ia.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/ina.txt"; bl_norm_file "$ROOT/ib.txt" /tmp/rootB "$ROOT/m2.txt" > "$ROOT/inb.txt"
if diff -q "$ROOT/ina.txt" "$ROOT/inb.txt" >/dev/null 2>&1; then bad="$bad [body lines that look like id entries were treated as ids]"; fi
ck "an id-looking body line survives verbatim" grep -q 'id task body-looking-id-1' "$ROOT/ina.txt"
r1round_bl_norm_file "$ROOT/ia.txt" /tmp/rootB > "$ROOT/r1ia.txt"; r1round_bl_norm_file "$ROOT/ib.txt" /tmp/rootB > "$ROOT/r1ib.txt"
ck "round-1 normaliser treats body id lines as ids (why the control matters)" diff -q "$ROOT/r1ia.txt" "$ROOT/r1ib.txt"
# negative control for the controls: the old normaliser cannot tell the first two apart either
old_bl_norm /tmp/rootB < "$ROOT/raw2.txt" > "$ROOT/o2.txt"; old_bl_norm /tmp/rootB < "$ROOT/raw3.txt" > "$ROOT/o3.txt"; old_bl_norm /tmp/rootB < "$ROOT/raw4.txt" > "$ROOT/o4.txt"
ck "old global normaliser masks a changed digest (why the control matters)" diff -q "$ROOT/o2.txt" "$ROOT/o3.txt"
ck "old global normaliser masks a changed 16-hex body (why the control matters)" diff -q "$ROOT/o2.txt" "$ROOT/o4.txt"
# ledger field masking works on PARSED paths only
printf '{"duration_seconds":5,"note":"{\\"sha256\\": \\"%s\\"}","contract":{"admission":{"history":"%s","receipt":{"sha256":"%s"},"admitted_at":17}, "receipt":{"sha256":"%s"}}}\n' "$A64" "$A64" "$A64" "$A64" > "$ROOT/led-a.json"
printf '{"duration_seconds":9,"note":"{\\"sha256\\": \\"%s\\"}","contract":{"admission":{"history":"%s","receipt":{"sha256":"%s"},"admitted_at":99}, "receipt":{"sha256":"%s"}}}\n' "$A64" "$B64" "$B64" "$B64" > "$ROOT/led-b.json"
printf '{"duration_seconds":9,"note":"{\\"sha256\\": \\"%s\\"}","contract":{"admission":{"history":"%s","receipt":{"sha256":"%s"},"admitted_at":99}, "receipt":{"sha256":"%s"}}}\n' "$B64" "$B64" "$B64" "$B64" > "$ROOT/led-c.json"
ck "volatile ledger paths are masked (equivalent ledgers compare equal)" [ "$(bl_ledger_json "$ROOT/led-a.json")" = "$(bl_ledger_json "$ROOT/led-b.json")" ]
if [ "$(bl_ledger_json "$ROOT/led-b.json")" = "$(bl_ledger_json "$ROOT/led-c.json")" ]; then bad="$bad [a non-volatile ledger field with a sha256-looking value was masked]"; fi
finish "r6_baseline_normaliser_masks_only_generated_ids_with_sensitivity_controls"

if [ -n "$BASELINE" ]; then
  echo "--- behavioural baseline: released scripts $BASELINE vs candidate $SCRIPTS"
  bad=""
  # Comparator controls: the released scripts are deterministic after normalisation
  # (same scenario twice => identical), and the comparator DOES notice a difference
  # (two different scenarios => not identical). Transcripts carry real content.
  bl_exec "$BASELINE" sc_done_ok; C1="$BL_LAST"; bl_exec "$BASELINE" sc_done_ok; C2="$BL_LAST"
  bl_exec "$BASELINE" sc_done_ack_failed; C3="$BL_LAST"
  ck "normalisation is deterministic on the release" diff -q "$C1" "$C2"
  if diff -q "$C1" "$C3" >/dev/null 2>&1; then bad="$bad [comparator did not notice two different scenarios]"; fi
  ckx "transcript has the ledger, the ack record and the transport log" 'grep -q "marked done" "$C1" && grep -q "\"last_ack\"" "$C1" && grep -q "^dispatch boss1" "$C1"'
  ck "transcript is substantial" [ "$(wc -l < "$C1" | tr -d ' ')" -gt 40 ]
  finish "baseline_comparator_controls_deterministic_and_sensitive"
  bad=""
  for sc in sc_done_ok sc_done_ack_inline sc_done_ack_failed sc_done_ack_queued sc_done_self sc_done_force_created sc_block_ok sc_block_ack_failed \
            sc_review_ok sc_review_force sc_review_reviewer_failed sc_review_assigner_failed sc_review_retry sc_review_self_reviewer \
            sc_illegal sc_refusals sc_lock_timeout sc_duration_failed sc_ledger_write_failed sc_env_faults; do
    bl_same "$sc"
  done
  finish "baseline_ordinary_helpers_identical_stdout_stderr_rc_ledger_artifacts_transport"
  bad=""
  for sc in sc_note_done_ok sc_note_block_ok sc_note_notify_failed sc_note_inline sc_note_refused; do bl_same "$sc"; done
  finish "baseline_note_file_paths_identical"
  bad=""
  bl_same sc_contract
  finish "baseline_contract_route_identical_to_release_no_scheduler_diag"
  # Intentional differences: exactly these three, nothing else.
  bad=""
  # (1) queued reviewer dispatch: only the recorded review_dispatch_status differs (delivered -> queued)
  sc_q() { bl_task assigned rev1; RUN_ENV=(DG_D_rev1=queued); run worker1 task-review.sh "$TID" "sha1"; bl_rec review; }
  bl_exec "$BASELINE" sc_q; OLDQ="$BL_LAST"; bl_exec "$SCRIPTS" sc_q; NEWQ="$BL_LAST"
  ck "old recorded delivered" grep -q '"review_dispatch_status": "delivered"' "$OLDQ"
  ck "new recorded queued" grep -q '"review_dispatch_status": "queued"' "$NEWQ"
  ck "only that field differs" [ "$(diff <(sed 's/"review_dispatch_status": "[a-z]*"/S/' "$OLDQ") <(sed 's/"review_dispatch_status": "[a-z]*"/S/' "$NEWQ") | wc -l | tr -d ' ')" = 0 ]
  finish "baseline_intentional_difference_1_queued_review_recorded_queued"
  bad=""
  # (2) packet write failure: old dispatched a broken packet; new does not dispatch
  sc_p() { bl_task assigned rev1; mkdir "$FX/home/prompts/$TID-review.md"; run worker1 task-review.sh "$TID" "sha1"; bl_rec review; BL_RC=$RC; BL_REVD=$(tcount dispatch rev1); BL_ASSD=$(tcount dispatch boss1); }
  bl_exec "$BASELINE" sc_p; OLDP="$BL_LAST"; O_RC=$BL_RC; O_REV=$BL_REVD; O_ASS=$BL_ASSD
  bl_exec "$SCRIPTS" sc_p; NEWP="$BL_LAST"; N_RC=$BL_RC; N_REV=$BL_REVD; N_ASS=$BL_ASSD
  ck "rc 0 both" [ "$O_RC" = 0 ] && ck "rc 0 new" [ "$N_RC" = 0 ]
  ck "old dispatched the reviewer a broken packet" [ "$O_REV" = 1 ]; ck "new does not dispatch the reviewer" [ "$N_REV" = 0 ]
  ck "assigner ack identical (1)" [ "$O_ASS" = 1 ] && ck "assigner ack new" [ "$N_ASS" = 1 ]
  ck "old recorded delivered" grep -q '"review_dispatch_status": "delivered"' "$OLDP"
  ck "old recorded a dispatch stamp" grep -qE '"review_dispatched_at": "' "$OLDP"
  if grep -qE '"review_dispatched_at": "' "$NEWP"; then bad="$bad [new recorded a dispatch stamp]"; fi
  finish "baseline_intentional_difference_2_packet_write_failure_no_reviewer_dispatch"
  bad=""
  # (3) last_ack lock failure: byte-identical human output/ledger; only the DIAG line is new
  sc_l() { bl_task assigned; RUN_ENV=(DG_HOOK_boss1="$ROOT/hook-lock.sh" DG_LOCK_ID="$TID" SESSION_SCHEDULER_LOCK_TIMEOUT_SECS=1); run worker1 task-done.sh "$TID" "x"; bl_rec "done"; BL_DN=$(dg_count); release_locks; }
  bl_exec "$BASELINE" sc_l; OLDL="$BL_LAST"; O_DN=$BL_DN
  bl_exec "$SCRIPTS" sc_l; NEWL="$BL_LAST"; N_DN=$BL_DN
  ck "old emits no diagnostic" [ "$O_DN" = 0 ]; ck "new emits the bookkeeping diagnostic" [ "$N_DN" = 1 ]
  ck "everything else identical" diff -q "$OLDL" "$NEWL"
  finish "baseline_intentional_difference_3_last_ack_lock_failure_only_adds_diag"
  bad=""
  # (4) R1, reporting only: the publication wrapper really renames then dies. rc, ledger bytes,
  # artifacts and transport are IDENTICAL to the release; only the human line (a false
  # "NOT marked done" becomes a neutral "result unconfirmed") and the added DIAG differ.
  sc_k1() { bl_task assigned rev1; RUN_ENV=(DG_MV_KILL=1); run worker1 task-done.sh "$TID" ok; bl_rec "done"; BL_RC=$RC; BL_ERRX="$ERR"; BL_DN=$(dg_count); BL_DC=$(dgf 1 .state_committed); }
  bl_exec "$BASELINE" sc_k1; OLDK="$BL_LAST"; O_RC=$BL_RC; O_ERR="$BL_ERRX"; O_DN=$BL_DN
  bl_exec "$SCRIPTS" sc_k1; NEWK="$BL_LAST"; N_RC=$BL_RC; N_ERR="$BL_ERRX"; N_DN=$BL_DN; N_DC="$BL_DC"
  ck "same rc (1)" [ "$O_RC" = 1 ] && ck "same rc new" [ "$N_RC" = 1 ]
  ck "ledger, artifacts and transport identical" [ "$(sed -n '/^## ledger/,$p' "$OLDK")" = "$(sed -n '/^## ledger/,$p' "$NEWK")" ]
  case "$O_ERR" in *"NOT marked done"*) [ "$O_DN" = 0 ] || bad="$bad [old run emitted a DIAG]" ;; *) bad="$bad [old text lacks the NOT-marked claim]" ;; esac
  case "$N_ERR" in *"NOT marked"*) bad="$bad [new text keeps the false claim]" ;; *"result unconfirmed"*) [ "$N_DN" = 1 ] && [ "$N_DC" = null ] || bad="$bad [new DIAG count/committed wrong: $N_DN $N_DC]" ;; *) bad="$bad [new text is not neutral]" ;; esac
  sc_k3() { bl_bt; }
  bl_bt() { bl_task review rev1; mk_draft rev1 d-base.md "baseline verdict body"; RUN_ENV=(DG_MV_KILL=3); run rev1 task-done.sh "$TID" --note-file "$DRAFT"; bl_rec "done"; BL_RC=$RC; BL_ERRX="$ERR"; BL_DN=$(dg_count); }
  bl_exec "$BASELINE" sc_k3; OLDO="$BL_LAST"; O_RC=$BL_RC; O_ERR="$BL_ERRX"; O_DN=$BL_DN
  bl_exec "$SCRIPTS" sc_k3; NEWO="$BL_LAST"; N_RC=$BL_RC; N_ERR="$BL_ERRX"; N_DN=$BL_DN
  ck "outcome kill: same rc (0)" [ "$O_RC" = 0 ] && ck "outcome kill: same rc new" [ "$N_RC" = 0 ]
  ck "outcome kill: ledger, artifacts and transport identical" [ "$(sed -n '/^## ledger/,$p' "$OLDO")" = "$(sed -n '/^## ledger/,$p' "$NEWO")" ]
  case "$O_ERR" in *"it stays 'pending'"*) [ "$O_DN" = 0 ] || bad="$bad [old outcome run emitted a DIAG]" ;; *) bad="$bad [old outcome text changed unexpectedly]" ;; esac
  case "$N_ERR" in *"could not confirm"*) [ "$N_DN" = 1 ] || bad="$bad [new outcome DIAG count $N_DN]" ;; *) bad="$bad [new outcome text is not neutral]" ;; esac
  finish "baseline_intentional_difference_4_unconfirmed_publication_reporting_only"
else
  echo "--- behavioural baseline skipped (set DIAG_BASELINE_DIR to the released scripts directory)"
fi

echo
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
  exit 1
fi
