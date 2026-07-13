#!/usr/bin/env bash
# Hermetic smoke tests for session-context lifecycle, hook, and share transport.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/session-context-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_contains() {
  local file="$1" expected="$2"
  grep -Fq -- "$expected" "$file" || fail "$file did not contain: $expected"
}

path_mode() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null
}

assert_mode() {
  local expected="$1" path="$2" actual
  actual=$(path_mode "$path")
  [ "$actual" = "$expected" ] || fail "$path mode was $actual, expected $expected"
}

# GNU stat's -f flag reports filesystem details rather than selecting a format.
# Assert that successful GNU formatting wins and that BSD formatting remains a
# clean fallback, independent of the host that runs this suite.
if ! bash -c '
  stat() {
    case "$1:$2" in
      -c:%u) printf "501\n" ;;
      -c:%a) printf "600\n" ;;
      -c:%d:%i) printf "7:11\n" ;;
      -f:*) printf "wrong-format\n" ;;
      *) return 1 ;;
    esac
  }
  source "$1"
  [ "$(_context_path_uid ignored)" = "501" ]
  [ "$(_context_path_mode ignored)" = "600" ]
  [ "$(_context_path_identity ignored)" = "7:11" ]
' _ "$SCRIPT_DIR/lib.sh"; then
  fail "context metadata helpers did not prefer GNU stat formatting"
fi

if ! bash -c '
  stat() {
    case "$1:$2" in
      -c:*) return 1 ;;
      -f:%u) printf "501\n" ;;
      -f:%Lp) printf "600\n" ;;
      -f:%d:%i) printf "7:11\n" ;;
      *) return 1 ;;
    esac
  }
  source "$1"
  [ "$(_context_path_uid ignored)" = "501" ]
  [ "$(_context_path_mode ignored)" = "600" ]
  [ "$(_context_path_identity ignored)" = "7:11" ]
' _ "$SCRIPT_DIR/lib.sh"; then
  fail "context metadata helpers did not fall back to BSD stat formatting"
fi

export SESSION_CONTEXT_HOME="$TMP/contexts"
export CODEX_HOME="$TMP/codex"

printf '# Session Context: alpha\n\nfirst version\n' > "$TMP/input.md"
bash "$SCRIPT_DIR/save-context.sh" alpha "$TMP/input.md" > "$TMP/save-1.out"
[ -f "$SESSION_CONTEXT_HOME/alpha.md" ] || fail "save did not create alpha.md"
assert_mode 700 "$SESSION_CONTEXT_HOME"
assert_mode 600 "$SESSION_CONTEXT_HOME/alpha.md"
STORE_ABS=$(cd "$SESSION_CONTEXT_HOME" && pwd -P)
STORE_SHELL=$(printf '%q' "$STORE_ABS")

bash "$SCRIPT_DIR/list-contexts.sh" > "$TMP/list.out"
assert_contains "$TMP/list.out" $'alpha\t3 lines'

printf '# Session Context: alpha\n\nsecond version\n' > "$TMP/input.md"
bash "$SCRIPT_DIR/save-context.sh" alpha "$TMP/input.md" > "$TMP/save-2.out"
bash "$SCRIPT_DIR/diff-context.sh" alpha --versions > "$TMP/versions.out"
assert_contains "$TMP/versions.out" "History versions for 'alpha'"
assert_mode 700 "$SESSION_CONTEXT_HOME/.history"
alpha_history=$(find "$SESSION_CONTEXT_HOME/.history" -type f -name 'alpha.*.md' -print -quit)
[ -n "$alpha_history" ] || fail "overwrite did not create alpha history"
assert_mode 600 "$alpha_history"

# Safe legacy stores migrate to owner-only modes. Exact 0400 auto contexts stay
# immutable instead of being broadened to 0600.
LEGACY_STORE="$TMP/legacy-contexts"
mkdir -m 755 "$LEGACY_STORE"
mkdir -m 755 "$LEGACY_STORE/.history"
printf 'legacy\n' > "$LEGACY_STORE/legacy.md"
printf 'auto\n' > "$LEGACY_STORE/auto.md"
printf 'weird\n' > "$LEGACY_STORE/weird.md"
printf 'history\n' > "$LEGACY_STORE/.history/legacy.20260710-000000Z.md"
chmod 644 "$LEGACY_STORE/legacy.md"
chmod 400 "$LEGACY_STORE/auto.md"
chmod 000 "$LEGACY_STORE/weird.md"
chmod 444 "$LEGACY_STORE/.history/legacy.20260710-000000Z.md"
SESSION_CONTEXT_HOME="$LEGACY_STORE" bash "$SCRIPT_DIR/list-contexts.sh" > "$TMP/legacy-list.out"
assert_mode 700 "$LEGACY_STORE"
assert_mode 700 "$LEGACY_STORE/.history"
assert_mode 600 "$LEGACY_STORE/legacy.md"
assert_mode 400 "$LEGACY_STORE/auto.md"
assert_mode 600 "$LEGACY_STORE/weird.md"
assert_mode 600 "$LEGACY_STORE/.history/legacy.20260710-000000Z.md"

# Concurrent first use must create one safe store and serialize atomic writers.
RACE_STORE="$TMP/race-contexts"
race_pids=()
for race_index in 1 2 3 4 5 6; do
  printf 'race %s\n' "$race_index" > "$TMP/race-$race_index.md"
  SESSION_CONTEXT_HOME="$RACE_STORE" \
    bash "$SCRIPT_DIR/save-context.sh" "race$race_index" "$TMP/race-$race_index.md" \
      > "$TMP/race-$race_index.out" 2>&1 &
  race_pids+=("$!")
done
race_failed=0
for race_pid in "${race_pids[@]}"; do
  wait "$race_pid" || race_failed=1
done
if [ "$race_failed" -eq 1 ]; then
  for race_index in 1 2 3 4 5 6; do
    printf '%s\n' "--- race$race_index ---" >&2
    sed -n '1,80p' "$TMP/race-$race_index.out" >&2
  done
  fail "concurrent store initialization/save failed"
fi
assert_mode 700 "$RACE_STORE"
for race_index in 1 2 3 4 5 6; do
  [ -f "$RACE_STORE/race$race_index.md" ] || fail "race$race_index snapshot is missing"
  assert_mode 600 "$RACE_STORE/race$race_index.md"
done
[ -z "$(find "$RACE_STORE" -name '.session-context.tmp.*' -print -quit)" ] \
  || fail "atomic save left a temporary file behind"

# Writer lock serializes saves (event-gated, no wall-clock race): while a holder
# holds the lock, a competing save BLOCKS (never races the holder's tree / temp)
# and completes once released. The holder waits for a RELEASE marker instead of
# sleeping, so it cannot release on its own and a descheduled test process cannot
# race the observation window. Markers live OUTSIDE the store so tree validation
# does not reject them.
LOCK_SERIAL_STORE="$TMP/lock-serial"; mkdir -p "$LOCK_SERIAL_STORE"
LS_ACQ="$TMP/ls-acquired"; LS_REL="$TMP/ls-release"; rm -f "$LS_ACQ" "$LS_REL"
(
  source "$SCRIPT_DIR/lib.sh"
  acquire_context_store_lock "$LOCK_SERIAL_STORE" >/dev/null 2>&1 || exit 1
  : > "$LS_ACQ"
  hw=0; while [ ! -e "$LS_REL" ] && [ "$hw" -lt 4000 ]; do sleep 0.05; hw=$((hw + 50)); done
  release_context_store_lock >/dev/null 2>&1
) &
ls_holder_pid=$!
ls_w=0; while [ ! -e "$LS_ACQ" ] && [ "$ls_w" -lt 3000 ]; do sleep 0.05; ls_w=$((ls_w + 50)); done
[ -e "$LS_ACQ" ] || fail "lock holder never acquired the writer lock"
printf 'lock probe\n' > "$TMP/ls-probe.md"
SESSION_CONTEXT_HOME="$LOCK_SERIAL_STORE" bash "$SCRIPT_DIR/save-context.sh" lockprobe "$TMP/ls-probe.md" \
  > "$TMP/ls-probe.out" 2>&1 &
ls_save_pid=$!
sleep 0.4   # let the save reach acquire; the holder cannot release until we signal
{ kill -0 "$ls_save_pid" 2>/dev/null && [ ! -f "$LOCK_SERIAL_STORE/lockprobe.md" ]; } \
  || fail "competing save did not block on the held writer lock"
: > "$LS_REL"   # signal the holder to release
wait "$ls_holder_pid" || fail "lock holder exited nonzero"
wait "$ls_save_pid" || fail "blocked save did not complete after the writer lock was released"
[ -f "$LOCK_SERIAL_STORE/lockprobe.md" ] || fail "blocked save produced no snapshot after release"

# A stale observer may briefly claim the current generation before discovering
# its token changed. The owner release path waits for that transient claim to be
# dropped instead of failing or spinning without a bound.
RELEASE_CLAIM_STORE="$TMP/release-claim-contexts"
mkdir -m 700 "$RELEASE_CLAIM_STORE"
if ! bash -c '
  source "$1"
  root="$2"
  acquire_context_store_lock "$root" || exit 1
  mkdir -m 700 "$root/.session-context.lock/.reclaim"
  (sleep 0.1; rmdir "$root/.session-context.lock/.reclaim") &
  dropper=$!
  release_context_store_lock || exit 1
  wait "$dropper" || exit 1
  [ ! -e "$root/.session-context.lock" ]
' _ "$SCRIPT_DIR/lib.sh" "$RELEASE_CLAIM_STORE"; then
  fail "writer release did not wait for a transient generation claim"
fi

# A kill -9-style stale writer lock is reclaimed only after its recorded PID
# is confirmed dead; the replacement PID file remains owner-only.
STALE_STORE="$TMP/stale-contexts"
mkdir -m 700 "$STALE_STORE"
mkdir -m 700 "$STALE_STORE/.session-context.lock"
dead_pid=999999
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$((dead_pid + 1))
done
printf '%s\n' "$dead_pid" > "$STALE_STORE/.session-context.lock/pid"
chmod 600 "$STALE_STORE/.session-context.lock/pid"
SESSION_CONTEXT_HOME="$STALE_STORE" bash -c '
  source "$1"
  root=$(get_contexts_dir) || exit 1
  acquire_context_store_lock "$root" || exit 1
  [ "$(sed -n "1p" "$root/.session-context.lock/pid")" = "$$" ] || exit 1
  [ "$(_context_path_mode "$root/.session-context.lock/pid")" = "600" ] || exit 1
  release_context_store_lock
' _ "$SCRIPT_DIR/lib.sh" || fail "dead writer lock was not safely reclaimed"
[ ! -e "$STALE_STORE/.session-context.lock" ] || fail "reclaimed writer lock was left behind"
[ -z "$(find "$TMP" -maxdepth 1 -name 'stale-contexts.session-context-stale.*' -print -quit)" ] \
  || fail "stale-lock quarantine was left behind"

# ABA regression: a waiter may observe a dead generation, get descheduled while
# that pathname turns over, then resume against a new live writer. The exact old
# lock+PID token must NOT authorize quarantining the replacement generation.
ABA_STORE="$TMP/aba-contexts"
mkdir -m 700 "$ABA_STORE"
if ! bash -c '
  source "$1"
  root="$2"
  mkdir -m 700 "$root/.session-context.lock"
  dead_pid=999999
  while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
  printf "%s\n" "$dead_pid" > "$root/.session-context.lock/pid"
  chmod 600 "$root/.session-context.lock/pid"
  old_token=$(_context_lock_generation_token "$root") || exit 1

  rm -f "$root/.session-context.lock/pid"
  rmdir "$root/.session-context.lock"
  mkdir -m 700 "$root/.session-context.lock"
  printf "%s\n" "$$" > "$root/.session-context.lock/pid"
  chmod 600 "$root/.session-context.lock/pid"
  new_token=$(_context_lock_generation_token "$root") || exit 1
  [ "$new_token" != "$old_token" ] || exit 1

  if _context_quarantine_lock_generation "$root" "$old_token" dead; then
    exit 1
  else
    rc=$?
  fi
  [ "$rc" -eq 2 ] || exit 1
  [ "$(_context_lock_generation_token "$root")" = "$new_token" ] || exit 1
  [ ! -e "$root/.session-context.lock/.reclaim" ] || exit 1
  [ -z "$(find "${root}.session-context-stale."* -maxdepth 0 -print -quit 2>/dev/null)" ] || exit 1
' _ "$SCRIPT_DIR/lib.sh" "$ABA_STORE"; then
  fail "stale generation token quarantined a replacement writer lock"
fi

# The lock directory permits an owner-only numeric PID plus the transient empty
# owner-only reclaim claim. Every other entry or claim shape remains rejected.
BAD_LOCK_STORE="$TMP/bad-lock-contexts"
mkdir -m 700 "$BAD_LOCK_STORE"
mkdir -m 700 "$BAD_LOCK_STORE/.session-context.lock"
printf '%s\n' "$$" > "$BAD_LOCK_STORE/.session-context.lock/pid"
printf 'unexpected\n' > "$BAD_LOCK_STORE/.session-context.lock/extra"
chmod 600 "$BAD_LOCK_STORE/.session-context.lock/pid" "$BAD_LOCK_STORE/.session-context.lock/extra"
if SESSION_CONTEXT_HOME="$BAD_LOCK_STORE" \
  bash "$SCRIPT_DIR/list-contexts.sh" > "$TMP/bad-lock.out" 2>&1; then
  fail "tree validator accepted an extra writer-lock file"
fi
assert_contains "$TMP/bad-lock.out" "unexpected file in context store"

BAD_RECLAIM_STORE="$TMP/bad-reclaim-contexts"
mkdir -m 700 "$BAD_RECLAIM_STORE"
mkdir -m 700 "$BAD_RECLAIM_STORE/.session-context.lock"
printf '%s\n' "$$" > "$BAD_RECLAIM_STORE/.session-context.lock/pid"
chmod 600 "$BAD_RECLAIM_STORE/.session-context.lock/pid"
mkdir -m 755 "$BAD_RECLAIM_STORE/.session-context.lock/.reclaim"
if SESSION_CONTEXT_HOME="$BAD_RECLAIM_STORE" \
  bash "$SCRIPT_DIR/list-contexts.sh" > "$TMP/bad-reclaim.out" 2>&1; then
  fail "tree validator accepted a loose writer-lock reclaim claim"
fi
assert_contains "$TMP/bad-reclaim.out" "reclaim claim must be mode 700"

INVALID_PID_STORE="$TMP/invalid-pid-contexts"
mkdir -m 700 "$INVALID_PID_STORE"
mkdir -m 700 "$INVALID_PID_STORE/.session-context.lock"
printf 'not-a-pid\n' > "$INVALID_PID_STORE/.session-context.lock/pid"
chmod 600 "$INVALID_PID_STORE/.session-context.lock/pid"
if SESSION_CONTEXT_HOME="$INVALID_PID_STORE" \
  bash "$SCRIPT_DIR/list-contexts.sh" > "$TMP/invalid-pid.out" 2>&1; then
  fail "tree validator accepted a non-numeric writer-lock PID"
fi
assert_contains "$TMP/invalid-pid.out" "invalid holder PID"

# A symlinked store root is rejected without writing through to its target.
ROOT_TARGET="$TMP/root-target"
mkdir "$ROOT_TARGET"
ln -s "$ROOT_TARGET" "$TMP/symlink-contexts"
if SESSION_CONTEXT_HOME="$TMP/symlink-contexts" \
  bash "$SCRIPT_DIR/save-context.sh" escaped "$TMP/input.md" > "$TMP/root-link.out" 2>&1; then
  fail "save accepted a symlinked SESSION_CONTEXT_HOME"
fi
[ ! -e "$ROOT_TARGET/escaped.md" ] || fail "save wrote through a symlinked store root"
assert_contains "$TMP/root-link.out" "cannot be a symbolic link"

# Nested snapshot symlinks and special files are rejected before reads/writes;
# the link target remains unchanged.
NESTED_STORE="$TMP/nested-contexts"
mkdir -m 700 "$NESTED_STORE"
printf 'do-not-change\n' > "$TMP/outside-context.md"
ln -s "$TMP/outside-context.md" "$NESTED_STORE/evil.md"
if SESSION_CONTEXT_HOME="$NESTED_STORE" \
  bash "$SCRIPT_DIR/load-context.sh" evil > "$TMP/nested-link.out" 2>&1; then
  fail "load accepted a nested snapshot symlink"
fi
assert_contains "$TMP/nested-link.out" "nested symbolic links are not allowed"
[ "$(cat "$TMP/outside-context.md")" = "do-not-change" ] || fail "nested symlink target was modified"
rm "$NESTED_STORE/evil.md"
mkfifo "$NESTED_STORE/special.md"
if SESSION_CONTEXT_HOME="$NESTED_STORE" \
  bash "$SCRIPT_DIR/list-contexts.sh" > "$TMP/special-file.out" 2>&1; then
  fail "list accepted a special file in the context store"
fi
assert_contains "$TMP/special-file.out" "special files are not allowed"
rm "$NESTED_STORE/special.md"

# Ownership rejection is exercised without privileged chown by replacing only
# the stat helper after sourcing the real guard.
if SESSION_CONTEXT_HOME="$LEGACY_STORE" bash -c '
  source "$1"
  _context_path_uid() { printf "999999\n"; }
  get_contexts_dir
' _ "$SCRIPT_DIR/lib.sh" > "$TMP/unowned.out" 2>&1; then
  fail "context guard accepted a path reported as unowned"
fi
assert_contains "$TMP/unowned.out" "not owned by the current user"

printf '%s\n' '{"hook_event_name":"SessionStart"}' \
  | PLUGIN_ROOT="$PLUGIN_ROOT" SESSION_CONTEXT_HOME="$SESSION_CONTEXT_HOME" \
    bash "$SCRIPT_DIR/detect-snapshots.sh" > "$TMP/hook.out"
assert_contains "$TMP/hook.out" '"hookEventName":"SessionStart"'
assert_contains "$TMP/hook.out" '$session-context:context-load'
grep -Fq 'bash \"$PLUGIN_ROOT/scripts/detect-snapshots.sh\"' "$PLUGIN_ROOT/hooks/hooks.json" \
  || fail "SessionStart hook does not use the runtime-provided PLUGIN_ROOT"

MOCK_BIN="$TMP/bin"
mkdir -p "$MOCK_BIN"
cat > "$MOCK_BIN/tmux" <<'MOCK_TMUX'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%s\n' "${MOCK_SENDER:-sender-test}" ;;
  list-panes) printf '%%2 target-test\n' ;;
  send-keys)
    printf '%s\n' "$*" >> "${TMUX_CAPTURE:?}"
    ;;
esac
MOCK_TMUX
chmod +x "$MOCK_BIN/tmux"

# The raw tmux fallback refuses externally assigned sender/target labels before
# resolving panes or emitting any keys.
: > "$TMP/invalid-label.capture"
if TMUX_CAPTURE="$TMP/invalid-label.capture" MOCK_SENDER='bad sender' \
  PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  bash -c 'source "$1"; send_message target-test hello' _ "$SCRIPT_DIR/lib.sh" \
    > "$TMP/invalid-sender.out" 2>&1; then
  fail "fallback accepted an invalid externally assigned sender label"
fi
assert_contains "$TMP/invalid-sender.out" "Label must contain only"
if TMUX_CAPTURE="$TMP/invalid-label.capture" \
  PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  bash -c 'source "$1"; send_message "bad target" hello' _ "$SCRIPT_DIR/lib.sh" \
    > "$TMP/invalid-target.out" 2>&1; then
  fail "fallback accepted an invalid target label"
fi
[ ! -s "$TMP/invalid-label.capture" ] || fail "invalid fallback label emitted tmux keys"

CHAT_STUB="$TMP/session-chat-stub"
mkdir -p "$CHAT_STUB/scripts"
cat > "$CHAT_STUB/scripts/send-message.sh" <<'CHAT_STUB_SCRIPT'
#!/usr/bin/env bash
printf '%s\n%s\n' "$1" "$2" > "${SESSION_CHAT_CAPTURE:?}"
CHAT_STUB_SCRIPT
chmod +x "$CHAT_STUB/scripts/send-message.sh"

SESSION_CHAT_CAPTURE="$TMP/session-chat.capture" \
  TMUX_CAPTURE="$TMP/tmux.capture" \
  PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  SESSION_CHAT_ROOT_OVERRIDE="$CHAT_STUB" \
  bash "$SCRIPT_DIR/share-context.sh" target-test alpha > "$TMP/share-chat.out"
assert_contains "$TMP/share-chat.out" 'Transport: session-chat'
assert_contains "$TMP/session-chat.capture" 'target-test'
assert_contains "$TMP/session-chat.capture" "Shared store: $STORE_ABS"
assert_contains "$TMP/session-chat.capture" "export SESSION_CONTEXT_HOME=$STORE_SHELL"
assert_contains "$TMP/session-chat.capture" '/session-context:context-load alpha'
assert_contains "$TMP/session-chat.capture" '$session-context:context-load alpha'

# A relative override must be canonicalized before it is sent to another pane.
(cd "$TMP" && SESSION_CHAT_CAPTURE="$TMP/session-chat-relative.capture" \
  TMUX_CAPTURE="$TMP/tmux.capture" PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  SESSION_CONTEXT_HOME=contexts SESSION_CHAT_ROOT_OVERRIDE="$CHAT_STUB" \
  bash "$SCRIPT_DIR/share-context.sh" target-test alpha > "$TMP/share-relative.out")
assert_contains "$TMP/session-chat-relative.capture" "Shared store: $STORE_ABS"

# Exact export text remains copy/paste safe for spaces and apostrophes.
SPECIAL_STORE="$TMP/context store's"
mkdir -p "$SPECIAL_STORE"
cp "$SESSION_CONTEXT_HOME/alpha.md" "$SPECIAL_STORE/alpha.md"
SPECIAL_ABS=$(cd "$SPECIAL_STORE" && pwd -P)
SPECIAL_SHELL=$(printf '%q' "$SPECIAL_ABS")
SESSION_CHAT_CAPTURE="$TMP/session-chat-special.capture" \
  TMUX_CAPTURE="$TMP/tmux.capture" PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  SESSION_CONTEXT_HOME="$SPECIAL_STORE" SESSION_CHAT_ROOT_OVERRIDE="$CHAT_STUB" \
  bash "$SCRIPT_DIR/share-context.sh" target-test alpha > "$TMP/share-special.out"
assert_contains "$TMP/session-chat-special.capture" "export SESSION_CONTEXT_HOME=$SPECIAL_SHELL"

: > "$TMP/tmux.capture"
cat > "$CHAT_STUB/scripts/send-message.sh" <<'CHAT_FAIL_SCRIPT'
#!/usr/bin/env bash
exit 1
CHAT_FAIL_SCRIPT
chmod +x "$CHAT_STUB/scripts/send-message.sh"
if TMUX_CAPTURE="$TMP/tmux.capture" \
  PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  SESSION_CHAT_ROOT_OVERRIDE="$CHAT_STUB" \
  bash "$SCRIPT_DIR/share-context.sh" target-test alpha > "$TMP/share-chat-fail.out" 2>&1; then
  fail "share succeeded after the hardened session-chat transport failed"
fi
[ ! -s "$TMP/tmux.capture" ] || fail "share bypassed a session-chat failure through raw tmux"

ISOLATED_ROOT="$TMP/session-context-isolated"
mkdir -p "$ISOLATED_ROOT"
cp -R "$PLUGIN_ROOT/scripts" "$ISOLATED_ROOT/scripts"
CACHE_HOME="$TMP/cache-codex"
mkdir -p "$CACHE_HOME/plugins/cache/legacy/session-chat/0.9.9/scripts"
mkdir -p "$CACHE_HOME/plugins/cache/current/session-chat/0.16.5/scripts"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CACHE_HOME/plugins/cache/legacy/session-chat/0.9.9/scripts/send-message.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$CACHE_HOME/plugins/cache/current/session-chat/0.16.5/scripts/send-message.sh"
CACHE_ROOT=$(CODEX_HOME="$CACHE_HOME" bash -c 'source "$1"; session_chat_root' _ "$ISOLATED_ROOT/scripts/lib.sh")
[ "$CACHE_ROOT" = "$CACHE_HOME/plugins/cache/current/session-chat/0.16.5" ] \
  || fail "session-chat cache resolver did not select the newest provider-independent version"

TMUX_CAPTURE="$TMP/tmux.capture" \
  PATH="$MOCK_BIN:$PATH" TMUX=mock TMUX_PANE=%1 \
  CODEX_HOME="$TMP/empty-codex" SESSION_CHAT_ROOT_OVERRIDE='' SESSION_CHAT_PLUGIN_ROOT='' \
  bash "$ISOLATED_ROOT/scripts/share-context.sh" target-test alpha > "$TMP/share-fallback.out"
assert_contains "$TMP/share-fallback.out" 'Transport: tmux-fallback'
assert_contains "$TMP/tmux.capture" '[context:alpha]'

# Prepare unrelated history and prove confirmed removal does not over-delete.
printf 'beta one\n' > "$TMP/beta.md"
bash "$SCRIPT_DIR/save-context.sh" beta "$TMP/beta.md" > /dev/null
printf 'beta two\n' > "$TMP/beta.md"
bash "$SCRIPT_DIR/save-context.sh" beta "$TMP/beta.md" > /dev/null
beta_history=$(find "$SESSION_CONTEXT_HOME/.history" -type f -name 'beta.*.md' -print -quit)
[ -n "$beta_history" ] || fail "beta history fixture is missing"

if bash "$SCRIPT_DIR/remove-context.sh" alpha > "$TMP/remove-guard.out" 2>&1; then
  fail "remove-context bypassed the --confirmed guard"
fi
assert_contains "$TMP/remove-guard.out" "--confirmed"
[ -f "$SESSION_CONTEXT_HOME/alpha.md" ] || fail "unguarded removal deleted alpha"

bash "$SCRIPT_DIR/remove-context.sh" alpha --confirmed > "$TMP/remove.out"
[ ! -e "$SESSION_CONTEXT_HOME/alpha.md" ] || fail "remove left alpha.md behind"
assert_contains "$TMP/remove.out" "history file(s)"
[ -z "$(find "$SESSION_CONTEXT_HOME/.history" -type f -name 'alpha.*.md' -print -quit)" ] \
  || fail "remove left alpha history behind"
[ -f "$beta_history" ] || fail "removing alpha deleted beta history"

# Confirmed cleanup also removes orphan history after the current snapshot has
# already disappeared, and errors only when neither live nor history data exists.
printf 'orphan one\n' > "$TMP/orphan.md"
bash "$SCRIPT_DIR/save-context.sh" orphan "$TMP/orphan.md" > /dev/null
printf 'orphan two\n' > "$TMP/orphan.md"
bash "$SCRIPT_DIR/save-context.sh" orphan "$TMP/orphan.md" > /dev/null
rm "$SESSION_CONTEXT_HOME/orphan.md"
orphan_history=$(find "$SESSION_CONTEXT_HOME/.history" -type f -name 'orphan.*.md' -print -quit)
[ -n "$orphan_history" ] || fail "orphan history fixture is missing"
bash "$SCRIPT_DIR/remove-context.sh" orphan --confirmed > "$TMP/remove-orphan.out"
assert_contains "$TMP/remove-orphan.out" "0 current snapshot and 1 history file(s)"
[ ! -e "$orphan_history" ] || fail "confirmed remove retained orphan history"
if bash "$SCRIPT_DIR/remove-context.sh" missing --confirmed > "$TMP/remove-missing.out" 2>&1; then
  fail "remove succeeded when neither current nor history data existed"
fi
assert_contains "$TMP/remove-missing.out" "No current or archived context snapshot"

if rg -n --glob '!test-session-context.sh' 'CODEX_PLUGIN_ROOT|plugins/cache/.*/session-context/[0-9]' "$PLUGIN_ROOT" >/dev/null; then
  fail "session-context still contains a fixed plugin-root or cache-version pin"
fi
rg -q 'request_user_input' "$PLUGIN_ROOT/skills/context-remove/SKILL.md" \
  || fail "context-remove lacks structured-input guidance"
rg -q 'separate Yes/No confirmation' "$PLUGIN_ROOT/skills/context-remove/SKILL.md" \
  || fail "context-remove lacks an explicit final confirmation"
rg -q 'remove-context.sh.*--confirmed' "$PLUGIN_ROOT/skills/context-remove/SKILL.md" \
  || fail "context-remove skill does not pass the post-confirmation script guard"
rg -q 'remove-context.sh.*--confirmed' "$PLUGIN_ROOT/commands/context-remove.md" \
  || fail "context-remove command does not pass the post-confirmation script guard"
rg -q 'trap handle_signal HUP INT TERM' "$SCRIPT_DIR/save-context.sh" \
  || fail "save-context signal handler can continue after releasing its lock"
rg -q 'trap handle_signal HUP INT TERM' "$SCRIPT_DIR/remove-context.sh" \
  || fail "remove-context signal handler can continue after releasing its lock"
rg -q 'does \*\*not\*\* copy' "$PLUGIN_ROOT/skills/session-context/SKILL.md" \
  || fail "session-context overview does not document notification-only sharing"

echo "session-context smoke tests passed"
