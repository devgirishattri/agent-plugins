#!/usr/bin/env python3
"""Deterministic lock interleavings in disposable stores, for both providers."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class LockTests(unittest.TestCase):
    def test_mixed_provider_contention(self):
        with tempfile.TemporaryDirectory(prefix="scheduler-lock-contention-") as directory:
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX"))}
            env.update(SESSION_SCHEDULER_HOME=directory,
                       SESSION_SCHEDULER_LOCK_TIMEOUT_SECS="10")
            root = Path(directory)
            (root / "locks").mkdir()
            (root / "count").write_text("0\n")
            processes = []
            for index in range(12):
                provider = "codex" if index % 2 else "claude"
                library = (ROOT / ("codex/plugins" if provider == "codex" else "plugins")
                           / "session-scheduler/scripts/lib.sh")
                script = '''
set -u
source "$1"
for iteration in 1 2 3; do
  if [ "$2" = codex ]; then acquire_task_lock abcdef12; else task_lock abcdef12; fi
  [ "$?" = 0 ] || exit 1
  mkdir "$SESSION_SCHEDULER_HOME/exclusive" || exit 2
  read -r count < "$SESSION_SCHEDULER_HOME/count"
  sleep 0.005
  printf '%s\n' "$((count+1))" > "$SESSION_SCHEDULER_HOME/count"
  rmdir "$SESSION_SCHEDULER_HOME/exclusive" || exit 3
  if [ "$2" = codex ]; then release_task_lock abcdef12; else task_unlock abcdef12; fi
  [ "$?" = 0 ] || exit 4
done
'''
                processes.append(subprocess.Popen(["bash", "-c", script, "mixed-lock-test", str(library), provider],
                                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            try:
                results = [(p, p.communicate(timeout=20)) for p in processes]
                for p, (stdout, stderr) in results:
                    self.assertEqual(p.returncode, 0, stdout + stderr)
                self.assertEqual((root / "count").read_text().strip(), "36")
                self.assertEqual(list((root / "locks").iterdir()), [])
            finally:
                for p in processes:
                    if p.poll() is None:
                        p.kill()
                        p.communicate()

    def run_case(self, provider, body):
        source = (ROOT / ("codex/plugins" if provider == "codex" else "plugins")
                  / "session-scheduler/scripts/lib.sh")
        source = Path(os.environ.get("LOCK_TEST_" + provider.upper() + "_LIB", source))
        with tempfile.TemporaryDirectory(prefix="scheduler-lock-regression-") as directory:
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX"))}
            env.update(SESSION_SCHEDULER_HOME=directory,
                       SESSION_SCHEDULER_LOCK_TIMEOUT_SECS="1")
            setup = '''
set -eu
source "$1"
mkdir -p "$LOCKS_DIR"
lock="$LOCKS_DIR/abcdef12.lock"
if [ "$2" = codex ]; then
  acquire() { acquire_task_lock abcdef12; }
  release() { release_task_lock abcdef12; }
else
  acquire() { task_lock abcdef12; }
  release() { task_unlock abcdef12; }
fi
'''
            result = subprocess.run(["bash", "-c", setup + body, "lock-test", str(source), provider],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, provider + ": " + result.stdout + result.stderr)

    def test_release_without_contention_control(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire || exit 1
release
[ ! -e "$lock" ]
acquire || exit 1
release
''')

    def test_release_with_inflight_reclaim_marker(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire || exit 1
# Inject the marker at the release boundary in either implementation. Old
# release removes pid first; new release moves the entire owned directory.
rm() {
  command rm "$@"
  if [ "$#" = 2 ] && [ "$1" = -f ] && [ "$2" = "$lock/pid" ]; then
    command mkdir "$lock/reclaim"
  fi
}
mv() {
  if [ "$1" = "$lock" ]; then command mkdir "$lock/reclaim"; fi
  command mv "$@"
}
release || true
unset -f rm mv
# The delayed waiter removes its marker. This cannot repair the old orphan.
rmdir "$lock/reclaim" 2>/dev/null || true
if [ -e "$lock" ]; then echo 'FAIL: release left an ownerless acquisition path' >&2; exit 1; fi
acquire || exit 1
release
''')

    def test_delayed_reclaim_cannot_touch_new_generation(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire || exit 1
mkdir "$SESSION_SCHEDULER_HOME/retired"
ready="$SESSION_SCHEDULER_HOME/ready"
proceed="$SESSION_SCHEDULER_HOME/proceed"
cat() {
  if [ "$1" = pid ]; then
    : > "$ready"
    n=0
    while [ ! -e "$proceed" ]; do
      n=$((n+1)); [ "$n" -lt 500 ] || return 2
      sleep 0.01
    done
  fi
  command cat "$@"
}
# A stale waiter holds a marker but has not rechecked the live owner yet.
(_scheduler_reclaim_lock "$lock" 999999 && exit 9; exit 0) &
waiter=$!
n=0
while [ ! -e "$ready" ]; do
  n=$((n+1)); [ "$n" -lt 500 ] || exit 2
  sleep 0.01
done
command mv "$lock" "$SESSION_SCHEDULER_HOME/retired/lock"
mkdir "$lock" "$lock/reclaim"
printf '999999\n' > "$lock/pid"
: > "$proceed"
wait "$waiter"
[ "$(command cat "$lock/pid")" = 999999 ]
[ -d "$lock/reclaim" ]
[ ! -e "$SESSION_SCHEDULER_HOME/retired/lock/reclaim" ]
''')

    def test_live_owner_is_not_stolen_and_dead_owner_is_reclaimed(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire || exit 1
if acquire 2>/dev/null; then echo 'stole live lock' >&2; exit 1; fi
[ "$(cat "$lock/pid")" = "$$" ]
release
# An acquirer can legitimately pause between mkdir and writing its PID.
mkdir "$lock"
if acquire 2>/dev/null; then echo 'stole unpublished lock' >&2; exit 1; fi
[ -d "$lock" ] && [ ! -e "$lock/pid" ]
rmdir "$lock"
# Use a real exited child's PID instead of guessing an unused PID.
sleep 0 &
dead=$!
wait "$dead"
mkdir "$lock"
printf '%s\n' "$dead" > "$lock/pid"
acquire || exit 1
[ "$(cat "$lock/pid")" = "$$" ]
release
''')

    def test_failed_rename_preserves_ownership(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire || exit 1
mv() { return 1; }
if release; then echo 'reported success after failed rename' >&2; exit 1; fi
unset -f mv
[ "$(cat "$lock/pid")" = "$$" ]
release
[ ! -e "$lock" ]
[ "$(find "$LOCKS_DIR" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" = 0 ]
''')


if __name__ == "__main__":
    unittest.main()
