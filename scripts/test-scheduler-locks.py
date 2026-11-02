#!/usr/bin/env python3
"""Deterministic lock interleavings in disposable stores, for both providers."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LIBS = {provider: ROOT / prefix / "session-scheduler/scripts/lib.sh"
        for provider, prefix in (("claude", "plugins"), ("codex", "codex/plugins"))}

# uutils mkdir (Rust coreutils, Ubuntu's default coreutils since 25.10) through
# 0.10.0 checks for an existing path, then calls mkdir(2) and ignores its error
# when the path is a directory by then. A process that loses the create race
# therefore exits 0. This model lets GNU and BSD hosts exercise that behavior.
UUTILS_MKDIR = """#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" = -p ] && exec "@REAL_MKDIR@" "$@"; done
for last in "$@"; do :; done
if [ -e "$last" ]; then echo "mkdir: $last: File exists" >&2; exit 1; fi
"@REAL_MKDIR@" "$@" 2>/dev/null || [ -d "$last" ]
"""

# Deterministic form of the same outcome for a single shell: mkdir reports
# success when the directory already exists.
RACE_LOSING_MKDIR = '''mkdir() { for last in "$@"; do :; done; command mkdir "$@" 2>/dev/null || [ -d "$last" ]; }'''


def install_uutils_mkdir(directory):
    bin_dir = Path(directory) / "uutils-bin"
    bin_dir.mkdir()
    shim = bin_dir / "mkdir"
    shim.write_text(UUTILS_MKDIR.replace("@REAL_MKDIR@", shutil.which("mkdir")))
    shim.chmod(0o755)
    return bin_dir


class LockTests(unittest.TestCase):
    def test_mixed_provider_contention(self):
        for mkdir in ("system", "uutils"):
            with self.subTest(mkdir=mkdir):
                self.run_contention(uutils_mkdir=mkdir == "uutils")

    def run_contention(self, uutils_mkdir):
        with tempfile.TemporaryDirectory(prefix="scheduler-lock-contention-") as directory:
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX"))}
            env.update(SESSION_SCHEDULER_HOME=directory,
                       SESSION_SCHEDULER_LOCK_TIMEOUT_SECS="10")
            if uutils_mkdir:
                env["PATH"] = str(install_uutils_mkdir(directory)) + os.pathsep + env["PATH"]
            root = Path(directory)
            (root / "locks").mkdir()
            (root / "count").write_text("0\n")
            processes = []
            for index in range(12):
                provider = "codex" if index % 2 else "claude"
                library = LIBS[provider]
                # The overlap probe is an O_EXCL create, so it does not depend on
                # the mkdir under test.
                script = '''
set -u
source "$1"
for iteration in 1 2 3; do
  if [ "$2" = codex ]; then acquire_task_lock abcdef12; else task_lock abcdef12; fi
  [ "$?" = 0 ] || exit 1
  ( set -o noclobber; : > "$SESSION_SCHEDULER_HOME/exclusive" ) || exit 2
  read -r count < "$SESSION_SCHEDULER_HOME/count"
  sleep 0.005
  printf '%s\n' "$((count+1))" > "$SESSION_SCHEDULER_HOME/count"
  rm "$SESSION_SCHEDULER_HOME/exclusive" || exit 3
  if [ "$2" = codex ]; then release_task_lock abcdef12; else task_unlock abcdef12; fi
  [ "$?" = 0 ] || exit 4
done
'''
                processes.append(subprocess.Popen(["bash", "-c", script, "mixed-lock-test", str(library), provider],
                                                   env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            try:
                results = [(p, p.communicate(timeout=20)) for p in processes]
                # Report every failed writer. A writer that exits while holding
                # the lock stays an unreaped zombie, so earlier writers only show
                # a timeout and the root cause is in a later one.
                failures = ["writer %d exited %d: %s" % (index, p.returncode, (stdout + stderr).strip())
                            for index, (p, (stdout, stderr)) in enumerate(results) if p.returncode]
                self.assertEqual(failures, [], "\n".join(failures))
                self.assertEqual((root / "count").read_text().strip(), "36")
                self.assertEqual(list((root / "locks").iterdir()), [])
            finally:
                for p in processes:
                    if p.poll() is None:
                        p.kill()
                        p.communicate()

    def run_case(self, provider, body):
        source = Path(os.environ.get("LOCK_TEST_" + provider.upper() + "_LIB", LIBS[provider]))
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

    def test_release_between_safety_checks_retries(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
mkdir "$lock"
printf '%s\\n' "$$" > "$lock/pid"
released=0
# Deterministically release after mkdir failed, at the directory stat. On
# Claude this also follows the successful existence stat in the same guard.
function [() {
  if [[ "$#" = 4 && "$1" = '!' && "$2" = -d && "$3" = "$lock" && "$released" = 0 ]]; then
    command rm -rf "$lock"
    released=1
  fi
  builtin [ "$@"
}
acquire || exit 1
[[ "$released" = 1 ]] || exit 2
unset -f '['
[ "$(cat "$lock/pid")" = "$$" ]
release
[ ! -e "$lock" ]
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

    def test_mkdir_success_does_not_prove_ownership(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire || exit 1
# A second process whose mkdir loses the create race but still exits 0.
if bash -c '
  source "$1"
  ''' + RACE_LOSING_MKDIR + '''
  if [ "$2" = codex ]; then acquire_task_lock abcdef12; else task_lock abcdef12; fi
' second-writer "$1" "$2" 2>/dev/null; then
  echo 'a second process acquired a held lock' >&2; exit 1
fi
[ "$(cat "$lock/pid")" = "$$" ] || { echo 'the holder pid was overwritten' >&2; exit 1; }
release
[ ! -e "$lock" ]
''')

    def test_reclaim_marker_is_exclusive(self):
        for provider in ("codex", "claude"):
            with self.subTest(provider=provider):
                self.run_case(provider, RACE_LOSING_MKDIR + '''
sleep 0 &
dead=$!
wait "$dead"
command mkdir "$lock"
printf '%s\n' "$dead" > "$lock/pid"
# Another reclaimer is mid-takeover: a file marker, or the directory marker
# that earlier releases create.
for marker in file dir; do
  if [ "$marker" = dir ]; then command mkdir "$lock/reclaim"; else : > "$lock/reclaim"; fi
  if _scheduler_reclaim_lock "$lock" "$dead"; then
    echo "reclaimed past an in-flight $marker marker" >&2; exit 1
  fi
  [ "$(cat "$lock/pid")" = "$dead" ] || exit 2
  [ -e "$lock/reclaim" ] || { echo "removed another reclaimer's $marker marker" >&2; exit 3; }
  rm -rf "$lock/reclaim"
done
_scheduler_reclaim_lock "$lock" "$dead" || exit 4
[ "$(cat "$lock/pid")" = "$$" ]
[ ! -e "$lock/reclaim" ]
release
[ ! -e "$lock" ]
''')

    def test_lock_helpers_are_identical_across_providers(self):
        # Both providers share one lock protocol on a shared ledger.
        pattern = re.compile(r"^(_scheduler_(?:claim|reclaim|release)_lock)\(\) ([({])\n.*?^[)}]\n",
                             re.M | re.S)
        bodies = {provider: {m.group(1): m.group(0) for m in pattern.finditer(path.read_text())}
                  for provider, path in LIBS.items()}
        self.assertEqual(sorted(bodies["claude"]), ["_scheduler_claim_lock", "_scheduler_reclaim_lock",
                                                    "_scheduler_release_lock"])
        self.assertEqual(bodies["claude"], bodies["codex"])


if __name__ == "__main__":
    unittest.main()
