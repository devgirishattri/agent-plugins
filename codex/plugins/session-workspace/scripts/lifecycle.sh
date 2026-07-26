#!/usr/bin/env bash
# lifecycle.sh — Phase D shared topology engine used by workspace-start.sh
# and workspace-reconcile.sh (and read by workspace-status.sh for reporting).
#
# Core entry point: sw_process_plan PLAN_JSON, which walks every session in
# the resolved plan and, per pane slot, does exactly one of:
#   kept     — pane already healthy and managed -> untouched (idempotency)
#   started  — pane claimed (fresh split, or a blank unmanaged pane) and its
#              runtime launched via adapters.sh argv/env; also the outcome for
#              a managed pane whose runtime was never launched and is now
#              relaunched (see MARKER_LAUNCHED in tmux-lib.sh)
#   claimed  — pane claimed, but its runtime launch was suppressed by
#              --no-agents/--no-services; explicitly NOT healthy, so a later
#              run without that flag launches it
#   adopted  — an unmanaged pane occupying the slot was claimed via
#              --adopt --confirmed, after printing the adoption plan
#   skipped  — an optional pane whose cwd never resolved, or a pane whose
#              launch this run suppresses
#   failed   — an unmanaged pane occupies the slot and adoption was not
#              requested/confirmed: the slot is left completely untouched
#   planned  — DRY_RUN mode: nothing mutated, only reported
#
# A same-named tmux SESSION that carries no managed marker is handled by the
# same rules one level up: refused (with the real remedy) unless --adopt
# --confirmed, adopted only after its plan is printed, never in a dry run.
#
# Caller contract (globals set before calling sw_process_plan):
#   CONFIG_PATH     resolved config path
#   PROJECT_ID      project.id
#   DRY_RUN         0|1 — 1 means no tmux mutation of any kind
#   ALLOW_ADOPT     0|1 — --adopt --confirmed was passed
#   NO_AGENTS       0|1 — do not launch claude/codex-runtime panes
#   NO_SERVICES     0|1 — do not launch service-role panes' commands
# Populates: SW_FAILED_SLOTS (count), SW_CHANGED (count of started/adopted)
set -uo pipefail

# Resolve this library's own directory from ${BASH_SOURCE[0]}, never $0:
# this file is SOURCED, so $0 belongs to the caller — and for a `bash -c`
# or `bash -s` caller $0 is literally "bash", which resolved the sibling
# library against $PWD and broke depending on the working directory.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/lib.sh"
source "$HERE/tmux-lib.sh"

SW_FAILED_SLOTS=0
SW_CHANGED=0
SW_KEPT=0

_sw_report() {
  # $1=status $2=session $3=pane $4=detail
  printf '  [%s] %s / %s%s\n' "$1" "$2" "$3" "${4:+ — $4}"
}

# _sw_secret_loader_snippet SECRET_FILE — prints bash source text that, when
# prepended to a pane's launch script, reads "KEY=VALUE" lines from
# SECRET_FILE via the `read`/`export` BUILTINS (never `.`/`source`/`eval`, so
# a value like 'x=$(rm -rf ~)' is never re-parsed as code — export just
# stores the literal string), exports each into THIS pane's own process
# environment, and unlinks the file immediately. SECRET_FILE is a path, never
# secret material, so embedding it in the script (itself passed as a plain
# argv element to `bash -c`, never tmux-parsed, never logged) is safe.
#
# This — not `tmux set-environment -h` — is how a secret reaches a pane's
# process. Verified against the tmux(1) manual and by experiment: "Hidden
# variables are not passed into the environment of new processes and instead
# can only be used by tmux itself (for example in formats)." A pane created
# after `set-environment -h SESSION KEY VALUE` sees nothing in `printenv KEY`.
# Plain (non-hidden) `set-environment` was rejected too — FOR SECRETS: it is
# SESSION-scope, so every later pane in that session, not just the authorized
# one, would inherit it, and any pane can read it back with
# `show-environment`. That same session scope is exactly what makes plain
# `set-environment` the right mechanism for NON-secret pinned env, which is
# what _sw_pin_session_env below uses it for; the two are separate delivery
# paths on purpose, and no secret ever enters the session-env one.
_sw_secret_loader_snippet() {
  local path_q
  path_q="$(printf '%q' "$1")"
  cat <<EOF
if [ -f $path_q ]; then
  while IFS='=' read -r sw_secret_k sw_secret_v; do
    case "\$sw_secret_k" in
      [A-Za-z_]*) : ;;
      *) sw_secret_k="" ;;
    esac
    case "\$sw_secret_k" in
      *[!A-Za-z0-9_]*) sw_secret_k="" ;;
    esac
    [ -n "\$sw_secret_k" ] && export "\$sw_secret_k=\$sw_secret_v"
  done < $path_q
  rm -f $path_q
fi
EOF
}

# _sw_pin_session_env SESSION_NAME SESSION_JSON — execute
# env.groups.<g>.pin_to_session: mirror the pinned subset of each pane's env
# into the tmux SESSION environment, so a pane created LATER — including one
# the user splits by hand, which this engine never touches — still inherits
# the coordination env. (The launchers this engine replaces did exactly this
# with ~14 `tmux set-environment` calls; it was added there after a real
# drift incident where a hand-made pane wrote to the wrong ledger.)
#
# Scope, matching what `workspace-plan` displays for the same config:
#   * env.groups.<g>.values of every group with pin_to_session: true that is
#     used by a role PRESENT IN THIS SESSION, and
#   * the coordination store vars implied by stores.pin.
# adapters.sh `session-env` decides that subset from the very same map that
# produces the pane's own `export K=V;` line, so the two can never diverge.
#
# NOT mirrored, ever (adapters.sh enforces; tests assert):
#   * secrets — a session variable is inherited by EVERY later pane, which is
#     the exact over-sharing the per-pane private-file delivery avoids;
#   * TMUX_PANE / SESSION_CHAT_PANE_NAME / KNOWLEDGE_PANE_NAME and the
#     pane_name_aliases — per-pane identity, and KNOWLEDGE_PANE_NAME is an
#     authorization boundary; a session-scoped value could make a worker pane
#     present itself as the orchestrator.
#
# Idempotent by construction: `set-environment` is an upsert keyed by name,
# and names are de-duplicated here before any tmux call is made.
_sw_pin_session_env() {
  local session_name="$1" session_json="$2"
  local -a pin_names=() pin_values=() done_roles=()
  local pane_name pane_role k v i n seen

  # One adapters.sh call per distinct ROLE, not per pane: the pinned subset is
  # by construction pane-independent (it excludes every per-pane var), so two
  # panes of the same role always yield the identical set.
  while IFS=$'\t' read -r pane_role pane_name; do
    [ -n "$pane_name" ] || continue
    seen=0
    n="${#done_roles[@]}"
    i=0
    while [ "$i" -lt "$n" ]; do
      if [ "${done_roles[$i]}" = "$pane_role" ]; then
        seen=1
        break
      fi
      i=$((i + 1))
    done
    [ "$seen" -eq 1 ] && continue
    done_roles+=("$pane_role")
    while IFS= read -r -d '' k && IFS= read -r -d '' v; do
      [ -n "$k" ] || continue
      seen=0
      n="${#pin_names[@]}"
      i=0
      while [ "$i" -lt "$n" ]; do
        if [ "${pin_names[$i]}" = "$k" ]; then
          seen=1
          break
        fi
        i=$((i + 1))
      done
      [ "$seen" -eq 1 ] && continue
      pin_names+=("$k")
      pin_values+=("$v")
    done < <(bash "$HERE/adapters.sh" session-env --config "$CONFIG_PATH" --pane "$pane_name" 2>/dev/null)
  done < <(printf '%s' "$session_json" | jq -r '(.panes // [])[] | [(.role // ""), .name] | @tsv')

  n="${#pin_names[@]}"
  [ "$n" -gt 0 ] || return 0
  i=0
  while [ "$i" -lt "$n" ]; do
    # Exact-match session targeting, and NAME/VALUE passed as plain argv
    # elements — no shell in between, so nothing here needs (or may have)
    # %q quoting. `--` terminates option parsing so a value beginning with
    # "-" can never be read as a flag.
    tmux set-environment -t "=$session_name" -- "${pin_names[$i]}" "${pin_values[$i]}" 2>/dev/null || \
      echo "WARNING: could not pin ${pin_names[$i]} into the session environment of \"$session_name\"" >&2
    i=$((i + 1))
  done
}

# _sw_launch_pane PANE_ID PANE_PLAN_JSON  — respawn PANE_ID running the
# resolved runtime/command with the canonical env exports. Never send-keys,
# never eval; argv is passed to `tmux respawn-pane -- bash -c SCRIPT bash
# ARGV...` so tmux execs it directly (no shell re-parses ARGV).
#
# Sets SW_LAUNCH_SUPPRESSED=1 (instead of launching) when --no-agents /
# --no-services applies to this pane. The caller uses that to decide whether
# the pane may be marked "launched": a suppressed pane is deliberately left in
# the repairable state, so a later run WITHOUT the flag still launches it.
SW_LAUNCH_SUPPRESSED=0

# _sw_launch_suppressed_for PANE_PLAN_JSON — true when the CURRENT run's
# --no-agents/--no-services flags would suppress this specific pane's launch.
# Same rule as _sw_launch_pane's own early returns, asked ahead of time so the
# per-slot loop can report "skipped" instead of pretending to repair a pane it
# is not going to launch.
_sw_launch_suppressed_for() {
  local pane_plan="$1" role runtime
  role="$(printf '%s' "$pane_plan" | jq -r '.role')"
  runtime="$(printf '%s' "$pane_plan" | jq -r '.runtime.name')"
  { [ "$runtime" != "shell" ] && [ "$NO_AGENTS" -eq 1 ]; } && return 0
  { [ "$role" = "service" ] && [ "$NO_SERVICES" -eq 1 ]; } && return 0
  return 1
}

_sw_launch_pane() {
  local pane_id="$1" pane_plan="$2"
  local pane_name role runtime cwd command_json has_command
  SW_LAUNCH_SUPPRESSED=0
  pane_name="$(printf '%s' "$pane_plan" | jq -r '.name')"
  role="$(printf '%s' "$pane_plan" | jq -r '.role')"
  runtime="$(printf '%s' "$pane_plan" | jq -r '.runtime.name')"
  cwd="$(printf '%s' "$pane_plan" | jq -r '.cwd // empty')"
  command_json="$(printf '%s' "$pane_plan" | jq -c '.command // empty')"
  has_command=0
  [ -n "$command_json" ] && [ "$command_json" != "null" ] && has_command=1

  if [ "$runtime" != "shell" ] && [ "$NO_AGENTS" -eq 1 ]; then
    SW_LAUNCH_SUPPRESSED=1
    return 0
  fi
  if [ "$role" = "service" ] && [ "$NO_SERVICES" -eq 1 ]; then
    SW_LAUNCH_SUPPRESSED=1
    return 0
  fi

  # Secret delivery (plan defect #1): resolved and gated entirely by
  # adapters.sh (secrets.allow / secrets.visible_to_roles / on_missing), which
  # writes a private, single-use "KEY=VALUE" file for exactly this pane (or
  # nothing, if this role is not in secrets.visible_to_roles) and prints only
  # its PATH. `on_missing: fail` makes adapters.sh exit non-zero, which MUST
  # abort this pane's launch (plan defect #2) rather than warn-and-continue.
  local secret_file=""
  secret_file="$(bash "$HERE/adapters.sh" secret-file --config "$CONFIG_PATH" --pane "$pane_name")"
  local secret_rc=$?
  if [ "$secret_rc" -ne 0 ]; then
    echo "ERROR: could not deliver required secret(s) for pane \"$pane_name\" (secrets.on_missing: fail)" >&2
    return 1
  fi

  local tmux_pane_id
  tmux_pane_id="$(tmux display-message -p -t "$pane_id" '#{pane_id}' 2>/dev/null)"

  local env_exports
  env_exports="$(bash "$HERE/adapters.sh" env-exports --config "$CONFIG_PATH" --pane "$pane_name" --tmux-pane "$tmux_pane_id")" || {
    echo "ERROR: could not build env exports for pane \"$pane_name\"" >&2
    [ -n "$secret_file" ] && rm -f "$secret_file"
    return 1
  }
  if [ -n "$secret_file" ]; then
    # $(...) strips the loader snippet's trailing newline, so concatenating
    # it directly with env_exports (which starts with "export ...") would
    # collapse the snippet's final "fi" into "fiexport ..." -- a syntax
    # error. The explicit newline restores the statement boundary.
    env_exports="$(_sw_secret_loader_snippet "$secret_file")"$'\n'"${env_exports}"
  fi

  local argv=()
  if [ "$runtime" != "shell" ]; then
    while IFS= read -r -d '' a; do
      argv+=("$a")
    done < <(bash "$HERE/adapters.sh" agent-argv --config "$CONFIG_PATH" --pane "$pane_name")
    if [ "${#argv[@]}" -eq 0 ]; then
      echo "ERROR: could not build agent argv for pane \"$pane_name\"" >&2
      return 1
    fi
  elif [ "$has_command" -eq 1 ]; then
    while IFS= read -r a; do
      [ -n "$a" ] && argv+=("$a")
    done < <(printf '%s' "$command_json" | jq -r '.[]')
  fi

  local script="$env_exports"
  local respawn_target=(-t "$pane_id")
  [ -n "$cwd" ] && respawn_target=(-t "$pane_id" -c "$cwd")

  if [ "${#argv[@]}" -eq 0 ]; then
    script="${script}exec \"\${SHELL:-/bin/bash}\" -l"
    tmux respawn-pane -k "${respawn_target[@]}" -- bash -c "$script"
  else
    script="${script}exec \"\$@\""
    tmux respawn-pane -k "${respawn_target[@]}" -- bash -c "$script" bash "${argv[@]}"
  fi
}

# _sw_claim_pane PANE_ID SESSION_ID PANE_PLAN_JSON — (unless suppressed)
# launch, then set the pane name and markers. Shared by "started", "adopted"
# and "relaunched" outcomes.
#
# ORDER IS LOAD-BEARING: the markers are the ONLY thing that makes a pane
# "managed" to every later run, and a managed live pane is reported healthy.
# Writing them before the launch therefore made a FAILED launch permanently
# indistinguishable from success -- the first run said "failed", and every
# `start`/`reconcile` after it said "kept (already healthy)" with exit 0 while
# no agent was running anywhere. Launching first means a failed launch leaves
# the pane exactly as it was found (unmarked, so it is re-attempted), and only
# a launch that really happened is recorded.
_sw_claim_pane() {
  local pane_id="$1" session_id="$2" pane_plan="$3"
  local pane_name role runtime
  pane_name="$(printf '%s' "$pane_plan" | jq -r '.name')"
  role="$(printf '%s' "$pane_plan" | jq -r '.role')"
  runtime="$(printf '%s' "$pane_plan" | jq -r '.runtime.name')"

  _sw_launch_pane "$pane_id" "$pane_plan" || return 1
  sw_set_pane_name "$pane_id" "$pane_name" || return 1
  sw_set_pane_markers "$pane_id" "$PROJECT_ID" "$pane_name" "$role" "$runtime" || return 1
  # Only a launch that actually ran is recorded as launched: a pane whose
  # launch was suppressed by --no-agents/--no-services stays repairable.
  if [ "$SW_LAUNCH_SUPPRESSED" -eq 0 ]; then
    sw_set_pane_launched "$pane_id" "$runtime" || return 1
  fi
}

# _sw_ensure_session SESSION_JSON -> prints the tmux session name on stdout
# and returns 0 if the session is usable (exists+managed, freshly created, or
# adopted under --adopt --confirmed); returns 1 (nothing on stdout) if the name
# is occupied by an unmanaged/foreign session and adoption was not requested,
# in which case it must never be touched.
#
# SESSION-LEVEL adoption exists because every session predating this plugin is
# unmarked: without it the FIRST `start` in a migrated project refused, and the
# remedy it named was impossible (--adopt was consulted only in the per-pane
# loop, so `reconcile --adopt --confirmed` failed identically). Adoption here
# is gated exactly like the pane-level kind: --adopt --confirmed only, an
# adoption plan printed FIRST, and never anything at all in a dry run.
_sw_adoption_plan_report() {
  local session_name="$1" window_index="$2"
  local pane_count foreign pid pproj ppane
  pane_count="$(tmux list-panes -t "=$session_name" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
  foreign=""
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    # Pane-SCOPE reads only (`show-options -p -v` does not inherit the
    # session-scope value the way #{@opt} format expansion does), so this
    # lists genuinely per-pane markers, never our own session marker echoed
    # back by every pane in the session.
    ppane="$(sw_get_pane_option "$pid" "$MARKER_PANE")"
    [ -n "$ppane" ] || continue
    pproj="$(sw_get_pane_option "$pid" "$MARKER_PROJECT")"
    foreign="${foreign}
    $pid project=${pproj:-<none>} pane=$ppane"
  done < <(tmux list-panes -t "=$session_name" -F '#{pane_id}' 2>/dev/null)

  # Reported on STDERR on purpose: this function's caller captures
  # _sw_ensure_session's STDOUT as the session name (see the dry-run note
  # below), so stdout is not a reporting channel here. Callers redirect
  # 2>&1 for the user, which preserves the plan-before-action ordering.
  echo "-- session adoption candidate --" >&2
  echo "  session:        $session_name" >&2
  echo "  window:         $window_index" >&2
  echo "  existing panes: ${pane_count:-0}" >&2
  if [ -n "$foreign" ]; then
    echo "  panes already carrying session-workspace markers:$foreign" >&2
  else
    echo "  panes already carrying session-workspace markers: (none)" >&2
  fi
}

_sw_ensure_session() {
  local session_json="$1" session_id session_name window_index
  session_id="$(printf '%s' "$session_json" | jq -r '.id')"
  session_name="$(printf '%s' "$session_json" | jq -r '.name')"
  window_index="$(printf '%s' "$session_json" | jq -r '.window_index // 0')"

  if tmux has-session -t "=$session_name" 2>/dev/null; then
    if sw_session_is_managed "$session_name" "$PROJECT_ID"; then
      printf '%s\n' "$session_name"
      return 0
    fi

    if [ "$ALLOW_ADOPT" -ne 1 ]; then
      echo "ERROR: session \"$session_name\" already exists and is not managed by session-workspace (project \"$PROJECT_ID\")." >&2
      echo "       Refusing to touch it. To adopt this existing session, review the plan and then claim it:" >&2
      echo "         workspace-reconcile $session_id --adopt --confirmed           # preview only, mutates nothing" >&2
      echo "         workspace-reconcile $session_id --apply --adopt --confirmed   # adopt it, then start its panes" >&2
      echo "       Alternatively kill or rename that session by hand and re-run start." >&2
      return 1
    fi

    _sw_adoption_plan_report "$session_name" "$window_index"
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  [would-adopt-session] $session_name — would be labelled managed by project \"$PROJECT_ID\"" >&2
      printf '%s\n' "$session_name"
      return 0
    fi
    if ! sw_set_session_markers "$session_name" "$PROJECT_ID" "$session_id"; then
      echo "ERROR: could not write managed markers while adopting session \"$session_name\"" >&2
      return 1
    fi
    echo "  [adopted-session] $session_name — now managed by project \"$PROJECT_ID\"" >&2
    printf '%s\n' "$session_name"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    # Stdout here is captured by the caller ("session_name=$(_sw_ensure_session
    # ...)") and MUST contain exactly the session name and nothing else — any
    # human-readable reporting belongs on stderr or is left to the caller
    # (which already prints a "would-create" line per pane once it knows this
    # is a fresh session). A prior version of this line called _sw_report,
    # which prints to stdout: the caller's command substitution then captured
    # BOTH lines, so session_name became a two-line string ("[would-create]
    # ...\nSESSION_NAME") and every later `-t "=$session_name"` targeted a
    # corrupted, multi-line value.
    printf '%s\n' "$session_name"
    return 0
  fi

  local start_dir
  start_dir="$(printf '%s' "$session_json" | jq -r '(.panes[0].cwd // empty)')"
  local new_args=(-d -s "$session_name")
  [ -n "$start_dir" ] && new_args+=(-c "$start_dir")
  if ! tmux new-session "${new_args[@]}" 2>/dev/null; then
    echo "ERROR: failed to create session \"$session_name\"" >&2
    return 1
  fi
  # Marker failure is FATAL, never swallowed: without the session marker this
  # engine cannot recognize its own session on the next run, and would then
  # (correctly, but uselessly) refuse to touch it as "unmanaged" forever.
  if ! sw_set_session_markers "$session_name" "$PROJECT_ID" "$session_id"; then
    echo "ERROR: created session \"$session_name\" but could not write its managed markers" >&2
    return 1
  fi
  printf '%s\n' "$session_name"
}

# _sw_ensure_window SESSION_NAME WINDOW_INDEX -> prints window target
# "=SESSION:INDEX" on stdout, creating the window if it does not yet exist.
_sw_ensure_window() {
  local session_name="$1" window_index="$2"
  local target="=$session_name:$window_index"
  if tmux list-windows -t "=$session_name" -F '#{window_index}' 2>/dev/null | grep -qx "$window_index"; then
    printf '%s\n' "$target"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    printf '%s\n' "$target"
    return 0
  fi
  tmux new-window -d -t "=$session_name:$window_index" 2>/dev/null || true
  printf '%s\n' "$target"
}

# _sw_split_extra_pane WINDOW_TARGET — splits the last pane in the window to
# add one more (a plain, unnamed 50/50 split — used only to fill a gap for a
# missing managed pane; the new pane is then claimed like any fresh split).
#
# Deliberately NOT "prints the pane id on stdout" (i.e. never call this as
# `x="$(_sw_split_extra_pane ...)"`): a command substitution forks a
# subshell, and any variable this function sets is then thrown away the
# instant the subshell exits — which is exactly how an earlier version of
# this fix silently lost the failure reason. Instead: call it as a plain
# statement, check its exit status, then read SW_LAST_SPLIT_PANE (success) or
# SW_LAST_SPLIT_ERROR (failure, tmux's own stderr — e.g. "no space for new
# pane") from the CURRENT shell. Never redirect tmux's stderr to /dev/null
# here — that reason is the single most useful diagnostic a caller has.
SW_LAST_SPLIT_PANE=""
SW_LAST_SPLIT_ERROR=""
_sw_split_extra_pane() {
  local window_target="$1" last_pane
  SW_LAST_SPLIT_PANE=""
  SW_LAST_SPLIT_ERROR=""
  last_pane="$(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null | tail -n1)"
  if [ -z "$last_pane" ]; then
    SW_LAST_SPLIT_ERROR="window \"$window_target\" has no panes to split from"
    return 1
  fi
  local new_pane err_file status
  err_file="$(mktemp 2>/dev/null)" || err_file=""
  if [ -n "$err_file" ]; then
    new_pane="$(tmux split-window -t "$last_pane" -h -l 50% -P -F '#{pane_id}' 2>"$err_file")"
    status=$?
    SW_LAST_SPLIT_ERROR="$(tr -d '\n' < "$err_file" 2>/dev/null)"
    rm -f "$err_file"
  else
    # mktemp unavailable: fall back to an uncaptured stderr rather than
    # losing the split attempt entirely; status/pane id are still correct.
    new_pane="$(tmux split-window -t "$last_pane" -h -l 50% -P -F '#{pane_id}')"
    status=$?
  fi
  if [ "$status" -ne 0 ] || [ -z "$new_pane" ]; then
    [ -n "$SW_LAST_SPLIT_ERROR" ] || SW_LAST_SPLIT_ERROR="tmux split-window failed (no pane id returned)"
    return 1
  fi
  SW_LAST_SPLIT_PANE="$new_pane"
}

# _sw_process_session SESSION_JSON — the per-session slot-filling loop.
_sw_process_session() {
  local session_json="$1"
  local session_id session_name layout_kind only_fresh window_index retain
  session_id="$(printf '%s' "$session_json" | jq -r '.id')"
  layout_kind="$(printf '%s' "$session_json" | jq -r '.layout.kind // "standard"')"
  only_fresh="$(printf '%s' "$session_json" | jq -r '.layout.only_when_fresh // false')"
  window_index="$(printf '%s' "$session_json" | jq -r '.window_index // 0')"
  retain="$(printf '%s' "$session_json" | jq -r '.retain_layout // false')"

  session_name="$(_sw_ensure_session "$session_json")" || { SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1)); return 0; }
  if [ "$DRY_RUN" -eq 1 ] && ! tmux has-session -t "=$session_name" 2>/dev/null; then
    # Nothing more can be planned for a session that does not exist yet.
    local pane_json pn pskip
    while IFS= read -r pane_json; do
      pn="$(printf '%s' "$pane_json" | jq -r '.name')"
      pskip="$(printf '%s' "$pane_json" | jq -r '.skip_unresolved // false')"
      if [ "$pskip" = "true" ]; then
        _sw_report "skipped" "$session_name" "$pn" "optional, cwd unavailable"
        continue
      fi
      _sw_report "would-create" "$session_name" "$pn" "fresh session"
    done < <(printf '%s' "$session_json" | jq -c '.panes[]')
    return 0
  fi

  # Mirror the pinned env into the SESSION before any pane is created, so a
  # pane the user makes by hand at any later moment inherits it too.
  if [ "$DRY_RUN" -eq 0 ]; then
    _sw_pin_session_env "$session_name" "$session_json"
  fi

  local window_target
  window_target="$(_sw_ensure_window "$session_name" "$window_index")"

  local panes_json pane_count
  panes_json="$(printf '%s' "$session_json" | jq -c '.panes')"
  pane_count="$(printf '%s' "$panes_json" | jq 'length')"

  # Ordered list of pane ids, index-aligned with panes_json, resolved either
  # via a fresh split-tree build, or via marker/positional matching against
  # whatever panes already exist in the window.
  local -a SLOT_PANES=()
  local existing_count
  existing_count="$(tmux list-panes -t "$window_target" -F '#{pane_id}' 2>/dev/null | wc -l | tr -d ' ')"
  [ -z "$existing_count" ] && existing_count=0

  if [ "$layout_kind" = "split_tree" ] && [ "$only_fresh" = "true" ] && [ "$existing_count" -eq 1 ] && [ "$DRY_RUN" -eq 0 ]; then
    local nodes_json pane_order_json order_id resolved_pane
    nodes_json="$(printf '%s' "$session_json" | jq -c '.layout.nodes')"
    pane_order_json="$(printf '%s' "$session_json" | jq -c '.layout.pane_order')"

    sw_mask_after_split_hook "$window_target"
    if sw_build_split_tree "$window_target" "$nodes_json"; then
      while IFS= read -r order_id; do
        resolved_pane="$(_sw_node_pane "$order_id")" || {
          echo "ERROR: split_tree: pane_order references unknown node \"$order_id\"" >&2
          SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
        }
        SLOT_PANES+=("$resolved_pane")
      done < <(printf '%s' "$pane_order_json" | jq -r '.[]')
    else
      echo "ERROR: split_tree construction failed for session \"$session_id\"" >&2
      SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
    fi
    sw_unmask_after_split_hook "$window_target"
  else
    # Standard layout, or a split_tree window that is no longer fresh
    # (already built by a previous run).
    #
    # Resolution is TWO passes, deliberately:
    #
    #   pass 1 — marker match. A pane carrying our project marker with this
    #            exact planned name owns the slot, wherever it sits in the
    #            window (survives user reordering).
    #
    #   pass 2 — gap filling. Only panes that are NOT already claimed by
    #            pass 1 and do NOT carry this project's marker at all are
    #            eligible, taken in pane_index order. Excluding our own
    #            marked panes is what stops a naive positional index from
    #            proposing to "adopt" a sibling managed pane after an
    #            earlier slot's pane died — the previous single-pass
    #            positional lookup did exactly that, turning a repairable
    #            gap into a bogus adoption prompt. A genuinely FOREIGN
    #            (unmarked) pane stays eligible here on purpose: the
    #            per-slot loop below is what then refuses to rename it
    #            without --adopt --confirmed.
    #
    #   pass 3 — no candidate left: split one new pane (mutating runs only).
    local i=0 pane_json pane_name found_pane pid pmark pproj
    while [ "$i" -lt "$pane_count" ]; do
      pane_json="$(printf '%s' "$panes_json" | jq -c ".[$i]")"
      pane_name="$(printf '%s' "$pane_json" | jq -r '.name')"
      found_pane=""
      while IFS=$'\t' read -r pid pproj pmark; do
        [ -z "$pid" ] && continue
        if [ "$pproj" = "$PROJECT_ID" ] && [ "$pmark" = "$pane_name" ]; then
          found_pane="$pid"
          break
        fi
      done < <(tmux list-panes -t "$window_target" -F "$(printf '#{pane_id}\t#{%s}\t#{%s}' "$MARKER_PROJECT" "$MARKER_PANE")" 2>/dev/null)
      SLOT_PANES+=("$found_pane")
      i=$((i + 1))
    done

    local -a SLOT_SPLIT_ERR=()
    local j claimed candidate slot_skip
    i=0
    while [ "$i" -lt "$pane_count" ]; do
      if [ -n "${SLOT_PANES[$i]}" ]; then
        i=$((i + 1))
        continue
      fi
      # An optional pane whose cwd never resolved (un-cloned child repo)
      # never claims a real pane at all -- neither an existing gap-fill
      # candidate nor a fresh split -- so it can never end up launched with
      # an empty/inherited cwd, and so it leaves the candidate pane free for
      # whatever slot actually needs it. The per-slot loop below reports it
      # "skipped" regardless of whether a candidate would have been found.
      pane_json="$(printf '%s' "$panes_json" | jq -c ".[$i]")"
      slot_skip="$(printf '%s' "$pane_json" | jq -r '.skip_unresolved // false')"
      if [ "$slot_skip" = "true" ]; then
        i=$((i + 1))
        continue
      fi
      candidate=""
      while IFS=$'\t' read -r pid pmark; do
        [ -z "$pid" ] && continue
        # Never steal a pane that already carries a pane-scope managed
        # marker. The discriminator MUST be MARKER_PANE, not MARKER_PROJECT:
        # MARKER_PROJECT is also set at SESSION scope, and tmux FORMAT
        # expansion (#{@opt}) inherits session options into every pane, so
        # every pane of a managed session reports the project marker whether
        # or not it is itself managed. MARKER_PANE is only ever written at
        # pane scope, so it is the one honest per-pane signal here.
        # (`show-options -p -v` does NOT inherit — that is why
        # sw_pane_is_managed/sw_pane_is_blank stay correct.)
        [ -n "$pmark" ] && continue
        claimed=0
        j=0
        while [ "$j" -lt "$pane_count" ]; do
          [ "${SLOT_PANES[$j]}" = "$pid" ] && claimed=1 && break
          j=$((j + 1))
        done
        [ "$claimed" -eq 1 ] && continue
        candidate="$pid"
        break
      done < <(tmux list-panes -t "$window_target" -F "$(printf '#{pane_index}\t#{pane_id}\t#{%s}' "$MARKER_PANE")" 2>/dev/null | sort -n | cut -f2-)
      if [ -z "$candidate" ] && [ "$DRY_RUN" -eq 0 ]; then
        # Called as a plain statement, NOT `x="$(_sw_split_extra_pane ...)"`
        # — see the function's header comment for why a command substitution
        # here would silently discard SW_LAST_SPLIT_ERROR.
        if _sw_split_extra_pane "$window_target"; then
          candidate="$SW_LAST_SPLIT_PANE"
        else
          SLOT_SPLIT_ERR[$i]="${SW_LAST_SPLIT_ERROR:-tmux split-window failed}"
          echo "ERROR: could not create pane \"$(printf '%s' "$pane_json" | jq -r '.name')\" in session \"$session_name\": ${SLOT_SPLIT_ERR[$i]}" >&2
        fi
      fi
      SLOT_PANES[$i]="$candidate"
      i=$((i + 1))
    done

    if [ "$layout_kind" != "split_tree" ] && [ "$DRY_RUN" -eq 0 ]; then
      local layout_name
      layout_name="$(printf '%s' "$session_json" | jq -r '.layout.name // "tiled"')"
      tmux select-layout -t "$window_target" "$layout_name" 2>/dev/null || true
    fi
  fi

  if [ "$DRY_RUN" -eq 0 ] && [ "$retain" = "true" ]; then
    sw_restore_layout "$PROJECT_ID" "$session_id" "$window_target" 2>/dev/null || true
  fi

  # Slot classification below runs IDENTICALLY in dry-run and --apply (only
  # the mutating calls — _sw_claim_pane / marker writes — are skipped in
  # dry-run, each guarded individually). This is what lets
  # `workspace-reconcile` (dry-run by default) show an accurate per-pane
  # preview — including the adoption-candidate block for an unmanaged
  # occupant — without ever mutating tmux. See workspace-reconcile.md, which
  # promises exactly this.
  local i=0 pane_json pane_name pane_id optional slot_idx
  while [ "$i" -lt "$pane_count" ]; do
    pane_json="$(printf '%s' "$panes_json" | jq -c ".[$i]")"
    pane_name="$(printf '%s' "$pane_json" | jq -r '.name')"
    optional="$(printf '%s' "$pane_json" | jq -r '.optional // false')"
    pane_id="${SLOT_PANES[$i]:-}"
    slot_idx="$i"
    i=$((i + 1))

    # An optional pane whose cwd never resolved (un-cloned child repo) is
    # skipped outright, even if pass 1/2 above happened to hand it a real
    # pane id (slot allocation is supposed to have excluded it already; this
    # is the defense-in-depth backstop for the split_tree path, which builds
    # every node in the layout unconditionally). Launching it would run the
    # pane's agent with an empty/inherited cwd -- silently the WRONG repo.
    if [ "$optional" = "true" ]; then
      local pane_skip_unresolved
      pane_skip_unresolved="$(printf '%s' "$pane_json" | jq -r '.skip_unresolved // false')"
      if [ "$pane_skip_unresolved" = "true" ]; then
        _sw_report "skipped" "$session_name" "$pane_name" "optional, cwd unavailable"
        continue
      fi
    fi

    if [ -z "$pane_id" ]; then
      # NOTE: this is NOT the "optional pane, cwd unavailable" case — that is
      # handled and `continue`d above (skip_unresolved="true"). Reaching here
      # with optional="true" means the cwd resolved just fine; the slot is
      # simply missing a pane (usually a failed split — see SLOT_SPLIT_ERR),
      # which is a real failure regardless of the pane's optional flag.
      # Conflating the two here previously let a failed split on an optional
      # pane report as a benign "skipped" and never increment
      # SW_FAILED_SLOTS, so a topology that came up short of its plan could
      # still print [started] for every pane it DID make and exit 0.
      local slot_reason="${SLOT_SPLIT_ERR[$slot_idx]:-no pane slot available}"
      if [ "$DRY_RUN" -eq 1 ]; then
        _sw_report "would-fail" "$session_name" "$pane_name" "$slot_reason"
        SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
      else
        _sw_report "failed" "$session_name" "$pane_name" "$slot_reason"
        SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
      fi
      continue
    fi

    if sw_pane_is_managed "$pane_id" "$PROJECT_ID" "$pane_name" && ! sw_pane_dead "$pane_id"; then
      # Managed and alive, but its configured runtime was never actually
      # launched (claimed under --no-agents/--no-services). That is a
      # REPAIRABLE state, not a healthy one: reporting it "kept (already
      # healthy)" would make --no-agents a one-way door in which the pane could
      # never later receive its agent. A plain start/reconcile --apply
      # finishes the job here.
      if ! sw_pane_launched "$pane_id"; then
        if _sw_launch_suppressed_for "$pane_json"; then
          _sw_report "skipped" "$session_name" "$pane_name" "claimed, runtime not launched (suppressed by --no-agents/--no-services); a later start without that flag launches it"
          continue
        fi
        if [ "$DRY_RUN" -eq 1 ]; then
          _sw_report "would-relaunch" "$session_name" "$pane_name" "managed, but its runtime was never launched"
          continue
        fi
        if _sw_claim_pane "$pane_id" "$session_id" "$pane_json"; then
          _sw_report "started" "$session_name" "$pane_name" "relaunched — managed pane had no runtime running"
          SW_CHANGED=$((SW_CHANGED + 1))
        else
          _sw_report "failed" "$session_name" "$pane_name" "relaunch failed"
          SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
        fi
        continue
      fi
      if [ "$DRY_RUN" -eq 1 ]; then
        _sw_report "would-keep" "$session_name" "$pane_name" "already healthy — would not be respawned"
      else
        _sw_report "kept" "$session_name" "$pane_name" "already healthy — not respawned"
        SW_KEPT=$((SW_KEPT + 1))
      fi
      continue
    fi

    if sw_pane_is_blank "$pane_id" || sw_pane_dead "$pane_id"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        _sw_report "would-start" "$session_name" "$pane_name" "$pane_id"
        continue
      fi
      if _sw_claim_pane "$pane_id" "$session_id" "$pane_json"; then
        if [ "$SW_LAUNCH_SUPPRESSED" -eq 1 ]; then
          _sw_report "claimed" "$session_name" "$pane_name" "$pane_id — runtime launch suppressed by --no-agents/--no-services; a later start without that flag launches it"
        else
          _sw_report "started" "$session_name" "$pane_name" "$pane_id"
        fi
        SW_CHANGED=$((SW_CHANGED + 1))
      else
        _sw_report "failed" "$session_name" "$pane_name" "launch failed"
        SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
      fi
      continue
    fi

    # Occupied by something else: an unmanaged pane, or a pane managed for a
    # DIFFERENT slot/project. Never rename/repurpose without explicit
    # adoption. This report is printed in dry-run too, so `--adopt
    # --confirmed` without `--apply` shows exactly what would be adopted.
    local occupant_cmd occupant_project occupant_name
    occupant_cmd="$(sw_pane_current_command "$pane_id")"
    occupant_project="$(sw_get_pane_option "$pane_id" "$MARKER_PROJECT")"
    occupant_name="$(sw_get_pane_option "$pane_id" "$MARKER_PANE")"

    echo "-- adoption candidate --"
    echo "  session:        $session_name"
    echo "  planned slot:   $pane_name"
    echo "  target pane:    $pane_id"
    echo "  current command: ${occupant_cmd:-unknown}"
    echo "  existing marker: project=${occupant_project:-<none>} pane=${occupant_name:-<none>}"

    if [ "$ALLOW_ADOPT" -eq 1 ]; then
      if [ "$DRY_RUN" -eq 1 ]; then
        _sw_report "would-adopt" "$session_name" "$pane_name" "$pane_id"
        continue
      fi
      if _sw_claim_pane "$pane_id" "$session_id" "$pane_json"; then
        _sw_report "adopted" "$session_name" "$pane_name" "$pane_id"
        SW_CHANGED=$((SW_CHANGED + 1))
      else
        _sw_report "failed" "$session_name" "$pane_name" "adoption launch failed"
        SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
      fi
    elif [ "$DRY_RUN" -eq 1 ]; then
      _sw_report "would-fail" "$session_name" "$pane_name" "unmanaged pane occupies this slot — left untouched. Re-run with --adopt --confirmed (via workspace-reconcile) after reviewing the plan above."
      SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
    else
      _sw_report "failed" "$session_name" "$pane_name" "unmanaged pane occupies this slot — left untouched. Re-run with --adopt --confirmed (via workspace-reconcile) after reviewing the plan above."
      SW_FAILED_SLOTS=$((SW_FAILED_SLOTS + 1))
    fi
  done

  if [ "$DRY_RUN" -eq 0 ] && [ "$retain" = "true" ]; then
    sw_save_layout "$PROJECT_ID" "$session_id" "$window_target" 2>/dev/null || true
  fi
}

# sw_process_plan PLAN_JSON [TARGET]
sw_process_plan() {
  local plan_json="$1" target="${2:-all}"
  SW_FAILED_SLOTS=0
  SW_CHANGED=0
  SW_KEPT=0
  local session_json
  while IFS= read -r session_json; do
    [ -z "$session_json" ] && continue
    if [ "$target" != "all" ]; then
      local sid
      sid="$(printf '%s' "$session_json" | jq -r '.id')"
      [ "$sid" = "$target" ] || continue
    fi
    _sw_process_session "$session_json"
  done < <(printf '%s' "$plan_json" | jq -c '.sessions[]')
}
