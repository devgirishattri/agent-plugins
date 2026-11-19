#!/usr/bin/env bash
# instances.sh — engine side of peer orchestrators (schema v6 with `peers`,
# 0.17.0). Sourced by the verbs that change state (start, stop, restart,
# reconcile --apply, show, hide) and by status and doctor.
#
# The engine records the extra orchestrator sessions and the worker panes it
# started in the project state file instances.json (config.sh reads and
# expands it). This file holds the write side, and the rules every mutating
# verb applies the same way:
#
#   * One preamble under the project lock (sw_inst_begin): reload the config,
#     remove records whose pane or session is gone, reload again, then work out
#     who is calling. Nothing here runs for a config without `peers`.
#   * A record is removed only when tmux ANSWERED the scan. A scan that failed
#     (no server, a permission error, a timeout) proves nothing, so it never
#     removes a record and never rewrites the file.
#   * The file is written only while this process holds the project lock, by
#     temp file and rename, and only after the config still validates with the
#     candidate records (generated names must not collide with declared ones).
#   * The caller is the harness pane named by SESSION_WORKSPACE_PANE_NAME,
#     checked against the pane marker of $TMUX_PANE. An orchestrator may not
#     start, stop, restart or reconcile an orchestrator session, use --force
#     or --owner, or act on a worker another orchestrator owns. A worker may
#     not run a mutating verb. Anyone else is the user.
#
# Caller contract: CONFIG_PATH, CONFIG_JSON and PROJECT_ID are set by the verb.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/config.sh"
source "$HERE/validate-config.sh"
source "$HERE/tmux-lib.sh"

# sw_inst_peers CONFIG_JSON — true for a schema-6 config with `peers`.
sw_inst_peers() {
  printf '%s' "$1" | jq -e '.schema_version == 6 and has("peers")' >/dev/null 2>&1
}

# sw_inst_report STATUS SESSION PANE DETAIL — same line shape as lifecycle.sh.
sw_inst_report() {
  printf '  [%s] %s / %s%s\n' "$1" "$2" "$3" "${4:+ — $4}"
}

# sw_inst_reload — read the config again (the state file may have changed
# while this process waited for the lock) and validate it.
sw_inst_reload() {
  CONFIG_JSON="$(load_workspace_config_raw "$CONFIG_PATH")" || return 1
  if ! validate_workspace_config "$CONFIG_JSON" "$CONFIG_PATH"; then
    echo "ERROR: config failed validation: $CONFIG_PATH" >&2
    print_validation_errors
    return 1
  fi
}

# --- tmux scan ----------------------------------------------------------------

SW_SCAN_PANES="[]"
SW_SCAN_SESSIONS="[]"

# sw_inst_scan — read every pane and session of the tmux server into
# SW_SCAN_PANES / SW_SCAN_SESSIONS. Returns 1 when tmux failed to answer for
# any reason; the caller must then change nothing. The exit status is taken
# from tmux itself, never from a pipeline or a process substitution.
sw_inst_scan() {
  local panes_raw sessions_raw
  SW_SCAN_PANES="[]"
  SW_SCAN_SESSIONS="[]"
  panes_raw="$(tmux list-panes -a -F "#{session_name}	#{pane_id}	#{$MARKER_PROJECT}	#{$MARKER_PANE}	#{pane_dead}	#{window_index}" 2>/dev/null)" || return 1
  sessions_raw="$(tmux list-sessions -F "#{session_name}	#{$MARKER_PROJECT}" 2>/dev/null)" || return 1
  SW_SCAN_PANES="$(printf '%s\n' "$panes_raw" | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t")
      | {session: .[0], pane_id: .[1], project: .[2], pane: .[3], dead: (.[4] == "1"), window: (.[5] | tonumber? // 0)})')" || return 1
  SW_SCAN_SESSIONS="$(printf '%s\n' "$sessions_raw" | jq -Rsc '
    split("\n") | map(select(length > 0) | split("\t") | {session: .[0], project: (.[1] // "")})')" || return 1
}

# --- state file ---------------------------------------------------------------

# sw_inst_write INSTANCES_JSON — write instances.json: temp file in the same
# directory, then rename. Refused unless this process holds the project lock,
# and never through a symlink.
sw_inst_write() {
  local json="$1" path dir tmp
  if [ "$SW_LOCK_ACQUIRED" -ne 1 ]; then
    echo "ERROR: internal: the instances file is written only under the project lock" >&2
    return 1
  fi
  path="$(sw_instances_path "$PROJECT_ID")"
  dir="$(dirname "$path")"
  if [ -L "$path" ]; then
    echo "ERROR: $path is a symlink; refusing to write it" >&2
    return 1
  fi
  mkdir -p "$dir" || { echo "ERROR: cannot create $dir" >&2; return 1; }
  tmp="$(mktemp "$dir/instances.json.XXXXXX")" || { echo "ERROR: cannot write $dir" >&2; return 1; }
  if ! printf '%s\n' "$json" > "$tmp" || ! mv -f "$tmp" "$path"; then
    rm -f "$tmp"
    echo "ERROR: could not write $path" >&2
    return 1
  fi
}

# sw_inst_commit NEW_INSTANCES_JSON [CHECK] — write the new records. With CHECK
# (the default) the config is loaded with the candidate first and must still
# validate, because the loader drops a bad record silently. On success
# CONFIG_JSON is the expanded config that includes the candidate.
sw_inst_commit() {
  local new="$1" check="${2:-1}" candidate
  if [ "$check" = "1" ]; then
    candidate="$(load_workspace_config_raw "$CONFIG_PATH" "" "$new")" || return 1
    if ! validate_workspace_config "$candidate" "$CONFIG_PATH"; then
      echo "ERROR: the new record gives names or sessions the config does not accept:" >&2
      print_validation_errors
      return 1
    fi
  fi
  sw_inst_write "$new" || return 1
  sw_inst_reload
}

# sw_inst_stale_filter INSTANCES_JSON — print the records that are still live,
# judged against CONFIG_JSON and the last scan. A worker is live when a
# non-dead pane carrying this project's marker and its name exists in its
# owner's tmux session (any window). An orchestrator copy is live when its tmux
# session exists and carries this project's marker; the workers it owns follow
# it.
sw_inst_stale_filter() {
  jq -nc --argjson inst "$1" --argjson cfg "$CONFIG_JSON" \
    --argjson panes "$SW_SCAN_PANES" --argjson sess "$SW_SCAN_SESSIONS" --arg pid "$PROJECT_ID" '
    ($cfg.sessions // []) as $S
    | ($cfg.harness.roles.orchestrator // "") as $orole
    | [$S[] | select((.instance.index // 1) > 1)
        | select(.name as $n | any($sess[]; .session == $n and .project == $pid))
        | .instance.index] as $live_copies
    | [$S[] | select((.instance.index // 1) == 1 or ((.instance.index // 0) as $i | $live_copies | index($i) != null))
        | .name as $sname | (.panes // [])[] | select(.role == $orole) | {key: .name, value: $sname}] | from_entries as $owners
    | ([$S[] | .name as $sname | (.panes // [])[] | select(.worker != null) | {pane: .name, session: $sname, worker: .worker}]) as $wpanes
    | {version: 1,
       orchestrators: [($inst.orchestrators // [])[] | select(.index as $i | $live_copies | index($i) != null) | {index}],
       workers: [($inst.workers // [])[] | . as $w
         | ($wpanes | map(select(.worker.checkout == $w.checkout and .worker.role == $w.role and .worker["label"] == $w["label"] and .worker.owner == $w.owner))[0]) as $p
         | select($p != null and ($owners[$w.owner] // null) == $p.session
             and any($panes[]; .session == $p.session and .project == $pid and .pane == $p.pane and (.dead | not)))
         | {checkout, role, "label": .["label"], owner, visible}]}'
}

# sw_inst_cleanup — remove stale records (see the header). Skipped, with the
# file untouched, when the config has no `peers` or the tmux scan failed. A
# rewrite reloads CONFIG_JSON.
sw_inst_cleanup() {
  local stored fresh
  sw_inst_peers "$CONFIG_JSON" || return 0
  sw_inst_scan || return 0
  stored="$(sw_read_instances "$PROJECT_ID")"
  fresh="$(sw_inst_stale_filter "$stored")" || return 0
  [ -n "$fresh" ] || return 0
  if [ "$(printf '%s' "$fresh" | jq -c '.')" != "$(printf '%s' "$stored" | jq -c '.')" ]; then
    sw_inst_commit "$(printf '%s' "$fresh" | jq -c '.')" 0 || return 1
  fi
}

# --- record edits (all under the lock; callers pass the result to commit) -------

sw_inst_with_orchestrator() {
  sw_read_instances "$PROJECT_ID" | jq -c --argjson n "$1" '
    if any(.orchestrators[]; .index == $n) then . else .orchestrators += [{index: $n}] end'
}

sw_inst_with_worker() {
  # CHECKOUT ROLE LABEL OWNER VISIBLE
  sw_read_instances "$PROJECT_ID" | jq -c --arg c "$1" --arg r "$2" --arg l "$3" --arg o "$4" --argjson v "$5" '
    .workers += [{checkout: $c, role: $r, "label": $l, owner: $o, visible: $v}]'
}

# sw_inst_drop_worker CHECKOUT ROLE LABEL — the records without that worker.
sw_inst_drop_worker() {
  sw_read_instances "$PROJECT_ID" | jq -c --arg c "$1" --arg r "$2" --arg l "$3" '
    .workers |= map(select((.checkout == $c and .role == $r and .["label"] == $l) | not))'
}

# sw_inst_drop_session SESSION_ID — the records without that session's copy
# (index above 1) and without the workers its orchestrator pane owned. Used
# after a session is gone for sure, so it does not wait for a scan.
sw_inst_drop_session() {
  local owners index
  owners="$(printf '%s' "$CONFIG_JSON" | jq -c --arg id "$1" --arg orole "$(printf '%s' "$CONFIG_JSON" | jq -r '.harness.roles.orchestrator // ""')" '
    [(.sessions // [])[] | select(.id == $id) | (.panes // [])[] | select(.role == $orole) | .name]')"
  index="$(printf '%s' "$CONFIG_JSON" | jq -r --arg id "$1" '[(.sessions // [])[] | select(.id == $id) | (.instance.index // 1)][0] // 1')"
  sw_read_instances "$PROJECT_ID" | jq -c --argjson owners "$owners" --argjson idx "$index" '
    .orchestrators |= map(select(.index != $idx))
    | .workers |= map(select(.owner as $o | $owners | index($o) | not))'
}

# sw_inst_set_visible CHECKOUT ROLE LABEL BOOL
sw_inst_set_visible() {
  sw_read_instances "$PROJECT_ID" | jq -c --arg c "$1" --arg r "$2" --arg l "$3" --argjson v "$4" '
    .workers |= map(if .checkout == $c and .role == $r and .["label"] == $l then .visible = $v else . end)'
}

# sw_inst_changed NEW_JSON — true when the records differ from the stored ones.
sw_inst_changed() {
  [ "$(printf '%s' "$1" | jq -c '.')" != "$(sw_read_instances "$PROJECT_ID" | jq -c '.')" ]
}

# --- caller identity ----------------------------------------------------------

SW_CALLER_NAME=""
SW_CALLER_KIND="user"

# sw_inst_normalize_state_home — make this process use the state home every
# pane of a peers workspace is launched with (sw_state_home: an absolute
# $XDG_STATE_HOME, else $HOME/.local/state). The project lock lives under
# sw_state_root, which reads $XDG_STATE_HOME raw, while instances.json is
# written under sw_state_home; a relative value would give processes in
# different directories different locks for one file. Call it as soon as the
# verb knows the config has `peers`, before the lock.
sw_inst_normalize_state_home() {
  XDG_STATE_HOME="$(sw_state_home)"
  export XDG_STATE_HOME
}

# sw_inst_canon_file PATH — the file's directory made canonical, plus its name.
sw_inst_canon_file() {
  local dir
  dir="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  printf '%s/%s\n' "$dir" "$(basename "$1")"
}

# sw_inst_identity_bound — true when the launch environment of this process
# points at THIS project: SESSION_WORKSPACE_CONFIG is this config, or
# SESSION_WORKSPACE_PROJECT_ROOT is this project's root, or $TMUX_PANE carries
# this project's pane marker. A caller of another project's workspace, or a
# plain terminal, is not bound and stays the user.
sw_inst_identity_bound() {
  local mine theirs root proot
  if [ -n "${SESSION_WORKSPACE_CONFIG:-}" ]; then
    theirs="$(sw_inst_canon_file "$SESSION_WORKSPACE_CONFIG")" || theirs=""
    mine="$(sw_inst_canon_file "$CONFIG_PATH")" || mine=""
    [ -n "$theirs" ] && [ "$theirs" = "$mine" ] && return 0
  fi
  if [ -n "${SESSION_WORKSPACE_PROJECT_ROOT:-}" ]; then
    root="$(canonicalize_dir "$SESSION_WORKSPACE_PROJECT_ROOT")" || root=""
    proot="$(printf '%s' "$CONFIG_JSON" | jq -r '.project.root // "."')"
    case "$proot" in
      /*) ;;
      *) proot="$(config_base_dir "$CONFIG_PATH")/$proot" ;;
    esac
    proot="$(canonicalize_dir "$proot")" || proot=""
    [ -n "$root" ] && [ "$root" = "$proot" ] && return 0
  fi
  if [ -n "${TMUX_PANE:-}" ] && [ "$(sw_get_pane_option "$TMUX_PANE" "$MARKER_PROJECT")" = "$PROJECT_ID" ]; then
    return 0
  fi
  return 1
}

# sw_caller_resolve — decide who runs this verb. A name that is not a pane-name
# string is dropped. When $TMUX_PANE carries this project's pane marker the
# marker must agree with the name (it fills in a missing name). A mismatch is
# refused with exit 1: someone is claiming another pane's identity.
# A caller that claims an identity (SESSION_WORKSPACE_PANE_NAME is set, or the
# pane marker supplies one) of THIS project must name a pane of the config.
# A name that is empty, malformed or no pane (for example a worker whose
# record was removed) is refused with exit 1: it is no basis for user
# authority. A caller with no identity, or one bound to another project, is
# the user.
sw_caller_resolve() {
  local raw="${SESSION_WORKSPACE_PANE_NAME-}" name marker="" proj pm claimed=0 bound=0
  name="$raw"
  [ "${SESSION_WORKSPACE_PANE_NAME+set}" = "set" ] && claimed=1
  case "$name" in
    *[!A-Za-z0-9._-]*) name="" ;;
  esac
  if [ -n "${TMUX_PANE:-}" ]; then
    proj="$(sw_get_pane_option "$TMUX_PANE" "$MARKER_PROJECT")"
    pm="$(sw_get_pane_option "$TMUX_PANE" "$MARKER_PANE")"
    [ "$proj" = "$PROJECT_ID" ] && marker="$pm"
  fi
  if [ -n "$marker" ]; then
    if [ -z "$name" ]; then
      name="$marker"
      raw="$marker"
    elif [ "$name" != "$marker" ]; then
      echo "ERROR: caller identity does not match this pane" >&2
      exit 1
    fi
    claimed=1
  fi
  SW_CALLER_NAME="$name"
  SW_CALLER_KIND="user"
  [ "$claimed" -eq 1 ] || return 0
  sw_inst_identity_bound && bound=1
  [ "$bound" -eq 1 ] || { SW_CALLER_NAME=""; return 0; }
  SW_CALLER_KIND="$([ -n "$name" ] && printf '%s' "$CONFIG_JSON" | jq -r --arg n "$name" '
    (.harness.roles // {}) as $r
    | ([(.sessions // [])[] | (.panes // [])[] | select(.name == $n)][0].role // "") as $role
    | if $role == "" then "unknown"
      elif $role == $r.orchestrator then "orchestrator"
      elif $role == $r.executor or $role == $r.reviewer then "worker"
      else "user" end' || echo unknown)"
  if [ -z "$SW_CALLER_KIND" ] || [ "$SW_CALLER_KIND" = "unknown" ]; then
    echo "ERROR: harness identity $raw is not a pane of this workspace; nothing was changed" >&2
    exit 1
  fi
}

# sw_caller_deny MESSAGE — refuse with exit 1; nothing has changed yet.
sw_caller_deny() {
  echo "ERROR: $1" >&2
  exit 1
}

# sw_caller_is_orchestrator_target TARGET — true when TARGET names an
# orchestrator session: the declared one, a copy, or a copy that is not
# recorded yet (matched by name, so `start development-3` is caught too).
sw_caller_is_orchestrator_target() {
  local ps
  ps="$(printf '%s' "$CONFIG_JSON" | jq -r '.peers.session // ""')"
  [ -n "$ps" ] || return 1
  [ "$1" = "$ps" ] && return 0
  [[ "$1" =~ ^${ps}-[0-9]+$ ]] && return 0
  printf '%s' "$CONFIG_JSON" | jq -e --arg t "$1" 'any((.sessions // [])[]; .id == $t and .instance != null)' >/dev/null 2>&1
}

# sw_caller_check_session_verb VERB TARGET_GIVEN TARGET WIDEN_ALL FORCE OWNER —
# the rules for a verb that acts on whole sessions. VERB is the word used in
# the message. Prints the refusal and exits 1; returns normally when allowed.
sw_caller_check_session_verb() {
  local verb="$1" given="$2" target="$3" widen="$4" force="$5" owner="$6"
  case "$SW_CALLER_KIND" in
    user) return 0 ;;
    worker) sw_caller_deny "orchestrator.peer_lifecycle: worker pane $SW_CALLER_NAME may not $verb" ;;
  esac
  [ "$force" -eq 0 ] || sw_caller_deny "orchestrator.peer_lifecycle: --force is for the user; orchestrator $SW_CALLER_NAME may not use it"
  [ -z "$owner" ] || sw_caller_deny "orchestrator.peer_lifecycle: --owner is for the user; orchestrator $SW_CALLER_NAME is the owner of the workers it starts"
  [ "$widen" -eq 0 ] || sw_caller_deny "orchestrator.peer_lifecycle: orchestrator $SW_CALLER_NAME may not $verb with --all"
  if [ "$given" -eq 0 ] || [ "$target" = "all" ]; then
    sw_caller_deny "orchestrator.peer_lifecycle: orchestrator $SW_CALLER_NAME may not $verb every session; name one session"
  fi
  if sw_caller_is_orchestrator_target "$target"; then
    sw_caller_deny "orchestrator.peer_lifecycle: orchestrator $SW_CALLER_NAME may not $verb the orchestrator session $target"
  fi
  return 0
}

# sw_caller_check_worker_verb VERB FORCE OWNER_GIVEN — the rules for a verb on
# one worker (stop --worker, show, hide, start --checkout). The ownership test
# is separate (sw_caller_require_owner), because it needs the worker.
sw_caller_check_worker_verb() {
  local verb="$1" force="$2" owner="$3"
  case "$SW_CALLER_KIND" in
    user) return 0 ;;
    worker) sw_caller_deny "orchestrator.peer_lifecycle: worker pane $SW_CALLER_NAME may not $verb" ;;
  esac
  [ "$force" -eq 0 ] || sw_caller_deny "orchestrator.peer_lifecycle: --force is for the user; orchestrator $SW_CALLER_NAME may not use it"
  [ -z "$owner" ] || sw_caller_deny "orchestrator.peer_lifecycle: --owner is for the user; orchestrator $SW_CALLER_NAME is the owner of the workers it starts"
  return 0
}

# sw_caller_require_owner SESSION PANE OWNER — an orchestrator caller acts only
# on its own workers. Another orchestrator's worker gives the [held] line and
# exit 3 (nothing has changed yet).
sw_caller_require_owner() {
  [ "$SW_CALLER_KIND" = "orchestrator" ] || return 0
  [ "$3" = "$SW_CALLER_NAME" ] && return 0
  sw_inst_report "held" "$1" "$2" "owner $3"
  exit 3
}

# sw_inst_begin — the preamble: reload the config under the lock, remove stale
# records, reload again if any were removed, then resolve the caller. Every
# mutating verb calls it right after taking the project lock, for a peers
# config only.
sw_inst_begin() {
  sw_inst_reload || exit 1
  # An identity that is no pane is refused before the cleanup writes anything;
  # the second resolve judges it again against the cleaned config (a worker
  # whose record the cleanup removed is no pane any more).
  sw_caller_resolve
  sw_inst_cleanup || exit 1
  sw_caller_resolve
}

# --- worker helpers -----------------------------------------------------------

# sw_worker_name CONFIG_JSON CHECKOUT ROLE LABEL — the generated pane name.
sw_worker_name() {
  printf '%s' "$1" | jq -r --arg c "$2" --arg r "$3" --arg l "$4" '
    .project.id + "-" + $c + "-" + $r + (if $l == "" then "" else "-" + $l end)'
}

# sw_worker_resolve CONFIG_JSON NAME — print the worker pane row as JSON
# {name, session_id, session_name, window_index, worker} for a worker's full
# pane name or the part after "<project.id>-"; nothing when there is none.
sw_worker_resolve() {
  printf '%s' "$1" | jq -c --arg n "$2" '
    .project.id as $pid
    | [(.sessions // [])[] | . as $s | (.panes // [])[] | select(.worker != null)
       | {name, session_id: $s.id, session_name: $s.name, window_index: ($s.window_index // 0), layout: ($s.layout.name // "tiled"), worker}]
    | (map(select(.name == $n))[0] // map(select(.name == ($pid + "-" + $n)))[0] // empty)'
}

# sw_pane_find_session_wide SESSION_NAME PANE_NAME — print the pane id of the
# live, managed pane with that name anywhere in the session (a hidden worker
# has a window of its own), and its window index, tab-separated. Nothing when
# there is none.
sw_pane_find_session_wide() {
  local pid pmark widx
  while IFS=$'\t' read -r pid pmark widx; do
    [ -n "$pid" ] || continue
    if [ "$pmark" = "$2" ] && sw_pane_is_managed "$pid" "$PROJECT_ID" "$2" && ! sw_pane_dead "$pid"; then
      printf '%s\t%s\n' "$pid" "$widx"
      return 0
    fi
  done < <(tmux list-panes -s -t "=$1" -F "$(printf '#{pane_id}\t#{%s}\t#{window_index}' "$MARKER_PANE")" 2>/dev/null)
  return 1
}

# sw_worker_store_args PLAN_JSON PANE_NAME — fill SW_STORE_ARGS with the
# --tasks-dir / --queue arguments agent-pane.py reads: the plan's scheduler
# task store and every inbox queue a session-chat send to that pane can land
# in (the plan's messages stores and both providers' default directories).
# Stop's busy check and start's leftover check read the same files.
SW_STORE_ARGS=()
sw_worker_store_args() {
  local plan="$1" pane="$2" tasks_dir="" dir
  SW_STORE_ARGS=()
  tasks_dir="$(printf '%s' "$plan" | jq -r --arg n "$pane" '
    ([.sessions[].panes[] | select(.name == $n) | .grants[]? | select(.store == "scheduler") | .path]
     + [.sessions[].panes[].grants[]? | select(.store == "scheduler") | .path])[0] // empty')"
  [ -n "$tasks_dir" ] && SW_STORE_ARGS+=(--tasks-dir "$tasks_dir/tasks")
  while IFS= read -r dir; do
    [ -n "$dir" ] && SW_STORE_ARGS+=(--queue "$dir/queue/$pane.tsv")
  done < <({ printf '%s' "$plan" | jq -r '[.sessions[].panes[].grants[]? | select(.store == "messages") | .path] | unique[]'
             printf '%s\n' "$HOME/.claude/messages" "${CODEX_HOME:-$HOME/.codex}/messages"; } | awk '!seen[$0]++')
}
