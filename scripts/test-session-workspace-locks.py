#!/usr/bin/env python3
"""session-workspace project lock interleavings, for both provider trees.

`start`, `reconcile --apply`, `stop` and the idle watcher's stops serialize on
one lock directory per project (tmux-lib.sh sw_lock_acquire). On-demand
workers make an orchestrator take that lock far more often, so it uses the
claim / in-place reclaim / rename-release protocol of the other plugins' locks.
"""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LIBS = {provider: Path(os.environ.get("LOCK_TEST_" + provider.upper() + "_LIB",
                                      ROOT / prefix / "session-workspace/scripts/tmux-lib.sh"))
        for provider, prefix in (("claude", "plugins"), ("codex", "codex/plugins"))}

# uutils mkdir (Rust coreutils) through 0.10.0 can exit 0 for the process that
# loses a create race. This model lets GNU and BSD hosts exercise it.
UUTILS_MKDIR = """#!/usr/bin/env bash
for arg in "$@"; do [ "$arg" = -p ] && exec "@REAL_MKDIR@" "$@"; done
for last in "$@"; do :; done
if [ -e "$last" ]; then echo "mkdir: $last: File exists" >&2; exit 1; fi
"@REAL_MKDIR@" "$@" 2>/dev/null || [ -d "$last" ]
"""

# Deterministic form of the same outcome for one shell.
RACE_LOSING_MKDIR = '''mkdir() { for last in "$@"; do :; done; command mkdir "$@" 2>/dev/null || [ -d "$last" ]; }'''

# A pid that belonged to a process that has exited and been reaped.
DEAD_PID = '''
sleep 0 &
dead=$!
wait "$dead"
'''


def clean_env(directory, **extra):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("SESSION_", "TMUX", "XDG_"))}
    env.update(HOME=directory, TMPDIR=directory, XDG_STATE_HOME=str(Path(directory) / "state"))
    env.update(extra)
    return env


def lock_dir(directory):
    return Path(directory) / "state" / "session-workspace" / "example-app" / "lock"


class LockTests(unittest.TestCase):
    def test_provider_trees_share_the_lock_code(self):
        self.assertEqual(LIBS["claude"].read_bytes(), LIBS["codex"].read_bytes())

    def test_contention(self):
        for mkdir in ("system", "uutils"):
            for provider in LIBS:
                with self.subTest(mkdir=mkdir, provider=provider):
                    self.run_contention(provider, uutils_mkdir=mkdir == "uutils")

    def run_contention(self, provider, uutils_mkdir):
        with tempfile.TemporaryDirectory(prefix="session-workspace-lock-") as directory:
            root = Path(directory)
            env = clean_env(directory, WORK=directory)
            if uutils_mkdir:
                bin_dir = root / "uutils-bin"
                bin_dir.mkdir()
                shim = bin_dir / "mkdir"
                shim.write_text(UUTILS_MKDIR.replace("@REAL_MKDIR@", shutil.which("mkdir")))
                shim.chmod(0o755)
                env["PATH"] = str(bin_dir) + os.pathsep + env["PATH"]
            (root / "count").write_text("0\n")
            # Each critical section is its own short-lived process, reaped at
            # once, like one `workspace stop --pane` call: a waiter that read
            # its pid just before the release sees a dead holder while the next
            # caller holds the lock. The overlap probe is an O_EXCL create.
            holder = '''
set -u
source "$1"
sw_lock_acquire example-app 60 || exit 1
( set -o noclobber; : > "$WORK/exclusive" ) 2>/dev/null || { echo "two holders at once" >&2; exit 2; }
read -r count < "$WORK/count"
sleep 0.005
printf '%s\\n' "$((count+1))" > "$WORK/count"
rm "$WORK/exclusive" || exit 3
sw_lock_release
'''
            writer = '''
for iteration in 1 2 3; do
  bash -c "$HOLDER" holder "$1" || exit "$?"
done
'''
            env["HOLDER"] = holder
            processes = [subprocess.Popen(["bash", "-c", writer, "writer", str(LIBS[provider])], env=env,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                         for _ in range(10)]
            try:
                results = [(p, p.communicate(timeout=120)) for p in processes]
                failures = ["writer %d exited %d: %s" % (index, p.returncode, (out + err).strip())
                            for index, (p, (out, err)) in enumerate(results) if p.returncode]
                self.assertEqual(failures, [], "\n".join(failures))
                self.assertEqual((root / "count").read_text().strip(), "30")
                self.assertFalse(lock_dir(directory).exists())
                self.assertEqual([p.name for p in lock_dir(directory).parent.iterdir() if p.name.startswith(".release")], [])
            finally:
                for p in processes:
                    if p.poll() is None:
                        p.kill()
                        p.communicate()

    def run_case(self, provider, body):
        with tempfile.TemporaryDirectory(prefix="session-workspace-lock-case-") as directory:
            lock = lock_dir(directory)
            lock.parent.mkdir(parents=True)
            env = clean_env(directory, LOCK=str(lock))
            script = 'set -u\nsource "$1"\n' + body
            result = subprocess.run(["bash", "-c", script, "case", str(LIBS[provider])], env=env,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_mkdir_success_does_not_prove_ownership(self):
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, '''
sw_lock_acquire example-app 5 || exit 1
if bash -c 'source "$1"; ''' + RACE_LOSING_MKDIR + '''; sw_lock_acquire example-app 1' second "$1" 2>/dev/null; then
  echo "a second process acquired a held lock" >&2; exit 1
fi
[ "$(cat "$LOCK/pid")" = "$$" ] || { echo "the holder pid was overwritten" >&2; exit 1; }
sw_lock_release
[ ! -e "$LOCK" ]
''')

    def test_race_losing_mkdir_still_acquires_a_free_lock(self):
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, RACE_LOSING_MKDIR + '''
sw_lock_acquire example-app 2 || exit 1
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
sw_lock_release
[ ! -e "$LOCK" ]
''')

    def test_stale_lock_is_taken_over_in_place(self):
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
command mkdir "$LOCK"
printf '%s\\n' "$dead" > "$LOCK/pid"
ino_before=$(ls -di "$LOCK" | awk '{print $1}')
sw_lock_acquire example-app 2 2>/dev/null || exit 1
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
[ "$(ls -di "$LOCK" | awk '{print $1}')" = "$ino_before" ] || { echo "the stale lock was replaced, not taken over" >&2; exit 3; }
[ ! -e "$LOCK/reclaim" ] || exit 4
sw_lock_release
[ ! -e "$LOCK" ]
''')

    def test_reclaim_never_takes_a_newer_holders_lock(self):
        # A waiter read a dead pid, then that lock was released and claimed by
        # a live process: the takeover must fail and leave the new holder.
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
command mkdir "$LOCK"
sleep 30 &
live=$!
printf '%s\\n' "$live" > "$LOCK/pid"
if _sw_reclaim_lock "$LOCK" "$dead"; then echo "took over a live holder's lock" >&2; kill "$live"; exit 1; fi
[ "$(cat "$LOCK/pid")" = "$live" ] || { kill "$live"; exit 2; }
[ ! -e "$LOCK/reclaim" ] || { kill "$live"; exit 3; }
kill "$live"
''')

    def test_release_only_by_the_holder(self):
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, '''
command mkdir "$LOCK"
printf '%s\\n' 1 > "$LOCK/pid"
SW_LOCK_DIR="$LOCK"; SW_LOCK_ACQUIRED=1
sw_lock_release
[ -d "$LOCK" ] && [ "$(cat "$LOCK/pid")" = 1 ] || { echo "released a lock it did not hold" >&2; exit 1; }
''')


if __name__ == "__main__":
    unittest.main(verbosity=2)
