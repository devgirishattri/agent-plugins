#!/usr/bin/env python3
"""knowledge context-store writer-lock interleavings, for both providers.

Claude and Codex writers can share one SESSION_CONTEXT_HOME, so the two libs
must exclude each other on the same .knowledge-context.lock directory.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LIBS = {provider: Path(os.environ.get("CONTEXT_LOCK_TEST_" + provider.upper() + "_LIB",
                                      ROOT / prefix / "knowledge/scripts/lib.sh"))
        for provider, prefix in (("claude", "plugins"), ("codex", "codex/plugins"))}

# uutils mkdir (Rust coreutils, the default on Ubuntu 25.10 and later) through
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
RACE_LOSING_MKDIR = '''mkdir() { for last in "$@"; do :; done; command mkdir "$@" 2>/dev/null || [ -d "$last" ]; }
'''

# A pid that belonged to a process that has exited and been reaped.
DEAD_PID = '''
sleep 0 &
dead=$!
wait "$dead"
'''


def install_uutils_mkdir(directory):
    bin_dir = Path(directory) / "uutils-bin"
    bin_dir.mkdir()
    shim = bin_dir / "mkdir"
    shim.write_text(UUTILS_MKDIR.replace("@REAL_MKDIR@", shutil.which("mkdir")))
    shim.chmod(0o755)
    return bin_dir


def clean_env(directory, **extra):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX"))}
    env.update(HOME=directory, TMPDIR=directory)
    env.update(extra)
    return env


def make_store(directory):
    """An empty owner-only context store and its writer-lock path."""
    store = Path(directory) / "contexts"
    store.mkdir(mode=0o700)
    store.chmod(0o700)
    return store, store / ".knowledge-context.lock"


class ContextLockTests(unittest.TestCase):
    def test_release_between_safety_checks_and_unsafe_controls(self):
        for provider, library in LIBS.items():
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                env = clean_env(directory)
                script = r'''
set -eu
source "$1"
root="$2"
chmod 700 "$root"
lock="$root/.knowledge-context.lock"
mkdir -m 700 "$lock"
released=0
function [() {
  if [[ "$#" = 4 && "$1" = '!' && "$2" = -d && "$3" = "$lock" && "$released" = 0 ]]; then
    command rmdir "$lock"
    released=1
  fi
  builtin [ "$@"
}
acquire_context_store_lock "$root" || exit 1
[[ "$released" = 1 ]] || exit 2
unset -f '['
[ "$(cat "$lock/pid")" = "$$" ]
release_context_store_lock
[ ! -e "$lock" ]
# A persistent unsafe path still fails closed, including a dangling symlink.
touch "$lock"
if acquire_context_store_lock "$root"; then exit 3; fi
[ -f "$lock" ]
rm "$lock"
ln -s "$root/missing" "$lock"
if acquire_context_store_lock "$root"; then exit 4; fi
[ -L "$lock" ]
'''
                result = subprocess.run(["bash", "-c", script, "context-lock-test", str(library), directory],
                                        env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_mixed_provider_contention(self):
        for mkdir in ("system", "uutils"):
            with self.subTest(mkdir=mkdir):
                self.run_contention(uutils_mkdir=mkdir == "uutils")

    def run_contention(self, uutils_mkdir):
        with tempfile.TemporaryDirectory(prefix="context-lock-contention-") as directory:
            work = Path(directory)
            store, _ = make_store(directory)
            env = clean_env(directory, STORE=str(store), WORK=directory)
            if uutils_mkdir:
                env["PATH"] = str(install_uutils_mkdir(directory)) + os.pathsep + env["PATH"]
            (work / "count").write_text("0\n")
            # Each critical section runs in its own short-lived process, like a
            # save-context.sh call: it exits as soon as it releases and is
            # reaped at once, so a waiter that read its pid just before the
            # release sees a dead holder while the next writer holds the lock.
            # The overlap probe is an O_EXCL create outside the store, so it
            # does not depend on the mkdir under test.
            holder = '''
set -u
source "$1"
acquire_context_store_lock "$STORE" || exit 1
( set -o noclobber; : > "$WORK/exclusive" ) 2>/dev/null || { echo "two holders at once" >&2; exit 2; }
read -r count < "$WORK/count"
sleep 0.005
printf '%s\\n' "$((count+1))" > "$WORK/count"
rm "$WORK/exclusive" || exit 3
release_context_store_lock || exit 4
'''
            writer = '''
for iteration in 1 2 3; do
  bash -c "$HOLDER" holder "$1" || exit "$?"
done
'''
            env["HOLDER"] = holder
            processes = []
            for index in range(8):
                provider = "codex" if index % 2 else "claude"
                processes.append(subprocess.Popen(["bash", "-c", writer, "writer", str(LIBS[provider])],
                                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            try:
                results = [(p, p.communicate(timeout=120)) for p in processes]
                # Report every failed writer. A writer that exits while holding
                # the lock strands it for the others, so the root cause can be in
                # any of them.
                failures = ["writer %d exited %d: %s" % (index, p.returncode, (stdout + stderr).strip())
                            for index, (p, (stdout, stderr)) in enumerate(results) if p.returncode]
                self.assertEqual(failures, [], "\n".join(failures))
                self.assertEqual((work / "count").read_text().strip(), "24")
                self.assertEqual(sorted(path.name for path in store.iterdir()), [])
            finally:
                for p in processes:
                    if p.poll() is None:
                        p.kill()
                        p.communicate()

    def run_case(self, provider, body, env_extra=None):
        """Run body in a shell that has sourced the provider's lib, with $STORE and $LOCK set."""
        with tempfile.TemporaryDirectory(prefix="context-lock-case-") as directory:
            store, lock = make_store(directory)
            env = clean_env(directory, STORE=str(store), LOCK=str(lock), **(env_extra or {}))
            script = 'set -u\nsource "$1"\n' + body
            result = subprocess.run(["bash", "-c", script, "case", str(LIBS[provider])],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_mkdir_success_does_not_prove_ownership(self):
        # A second writer whose mkdir loses the create race but still exits 0
        # must not take a held lock, from either provider against either, and
        # must take it once the holder releases.
        for holder in ("claude", "codex"):
            for second in ("claude", "codex"):
                with self.subTest(holder=holder, second=second):
                    self.run_case(holder, '''
acquire_context_store_lock "$STORE" || exit 1
bash -c '
  source "$1"
  ''' + RACE_LOSING_MKDIR + '''
  acquire_context_store_lock "$STORE" || exit 1
  [ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
  : > "$HOME/second-acquired"
  release_context_store_lock
' second-writer "$SECOND_LIB" &
second=$!
sleep 0.5
[ ! -e "$HOME/second-acquired" ] || { echo "a second writer acquired a held lock" >&2; exit 1; }
[ "$(cat "$LOCK/pid")" = "$$" ] || { echo "the holder pid was overwritten" >&2; exit 2; }
release_context_store_lock || exit 3
wait "$second" || { echo "the second writer did not acquire the released lock" >&2; exit 4; }
[ -e "$HOME/second-acquired" ] || exit 5
[ ! -e "$LOCK" ] || exit 6
''', env_extra={"SECOND_LIB": str(LIBS[second])})

    def test_race_losing_mkdir_still_acquires_a_free_lock(self):
        # The fix must not turn a lying mkdir into a lock nobody can take.
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, RACE_LOSING_MKDIR + '''
acquire_context_store_lock "$STORE" || exit 1
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
release_context_store_lock || exit 3
[ ! -e "$LOCK" ]
''')

    def test_stale_lock_is_taken_over_in_place(self):
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
command mkdir -m 700 "$LOCK"
printf '%s\\n' "$dead" > "$LOCK/pid"
before=$(_context_path_identity "$LOCK")
acquire_context_store_lock "$STORE" || exit 1
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
[ "$(_context_path_identity "$LOCK")" = "$before" ] || { echo "the stale lock was replaced, not taken over" >&2; exit 3; }
[ ! -e "$LOCK/.reclaim" ] || exit 4
release_context_store_lock || exit 5
[ -z "$(ls -A "$STORE")" ] || { echo "left $(ls -A "$STORE") behind" >&2; exit 6; }
''')

    def test_stale_reclaim_never_touches_a_newer_holder(self):
        # A waiter read a pid, and that holder released and exited before the
        # waiter checked it. Another writer holds the lock now. The waiter's
        # takeover must fail and leave the new holder's lock alone; moving the
        # directory away would give the lock two holders.
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
acquire_context_store_lock "$STORE" || exit 1
if _context_reclaim_lock "$LOCK" "$dead"; then
  echo "took over a lock held by a live process" >&2; exit 1
fi
[ "$(cat "$LOCK/pid")" = "$$" ] || { echo "the holder pid was overwritten" >&2; exit 2; }
[ ! -e "$LOCK/.reclaim" ] || exit 3
release_context_store_lock || exit 4
[ ! -e "$LOCK" ]
''')

    def test_reclaim_marker_is_exclusive(self):
        # Two waiters that saw the same dead pid: only the one that creates the
        # marker takes over, and it never removes another reclaimer's marker.
        # A 0.5.9 directory marker blocks a takeover the same way.
        for provider in LIBS:
            for marker in ("file", "directory"):
                with self.subTest(provider=provider, marker=marker):
                    self.run_case(provider, DEAD_PID + '''
command mkdir -m 700 "$LOCK"
printf '%s\\n' "$dead" > "$LOCK/pid"
if [ "$MARKER" = file ]; then : > "$LOCK/.reclaim"; else command mkdir -m 700 "$LOCK/.reclaim"; fi
if _context_reclaim_lock "$LOCK" "$dead"; then
  echo "reclaimed past an in-flight marker" >&2; exit 1
fi
[ "$(cat "$LOCK/pid")" = "$dead" ] || exit 2
[ -e "$LOCK/.reclaim" ] || { echo "removed another reclaimer's marker" >&2; exit 3; }
_context_validate_lock_artifact "$STORE" || exit 4
rm -rf "$LOCK/.reclaim"
_context_reclaim_lock "$LOCK" "$dead" || exit 5
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 6
[ ! -e "$LOCK/.reclaim" ] || exit 7
''', env_extra={"MARKER": marker})

    def test_release_by_a_non_holder_keeps_the_lock(self):
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, '''
command mkdir -m 700 "$LOCK"
printf '%s\\n' "$PPID" > "$LOCK/pid"
if _context_release_lock "$STORE"; then echo "released a lock held by another process" >&2; exit 1; fi
[ "$(cat "$LOCK/pid")" = "$PPID" ] || exit 2
[ "$(ls -A "$STORE")" = .knowledge-context.lock ] || exit 3
''')

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores directory write permission")
    def test_unwritable_pid_fails_closed_and_cleans_up(self):
        # A lock directory whose pid file cannot be created is not a held lock.
        # The acquirer reports it and removes the empty directory, so it does
        # not strand the lock for every later writer.
        for provider in LIBS:
            with self.subTest(provider=provider):
                self.run_case(provider, '''
mkdir() { command mkdir "$@" && chmod 500 "${@: -1}"; }
if acquire_context_store_lock "$STORE" 2>"$HOME/err"; then echo "acquired a lock without a holder pid" >&2; exit 1; fi
grep -q "cannot publish writer-lock holder PID" "$HOME/err" || { cat "$HOME/err" >&2; exit 2; }
[ ! -e "$LOCK" ] || { echo "left the empty lock directory behind" >&2; exit 3; }
''')

    def test_lock_helpers_are_identical_across_providers(self):
        # Both providers share one lock protocol on a shared store.
        names = ["_context_check_reclaim_marker", "_context_claim_lock", "_context_reclaim_lock",
                 "_context_release_lock", "_context_remove_quarantine_dir",
                 "acquire_context_store_lock", "release_context_store_lock"]
        pattern = re.compile(r"^(" + "|".join(names) + r")\(\) ([({])\n.*?^[)}]\n", re.M | re.S)
        bodies = {provider: {m.group(1): m.group(0) for m in pattern.finditer(path.read_text())}
                  for provider, path in LIBS.items()}
        self.assertEqual(sorted(bodies["claude"]), sorted(names))
        self.assertEqual(bodies["claude"], bodies["codex"])


if __name__ == "__main__":
    unittest.main()
