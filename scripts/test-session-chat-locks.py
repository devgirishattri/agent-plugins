#!/usr/bin/env python3
"""session-chat lock interleavings in disposable stores, for both providers.

The send lock and the per-recipient queue lock share one protocol in each
provider lib. A sender of either runtime can take a recipient's queue lock (a
Claude sender queues into a Codex pane's store, and the reverse), so the two
libs must exclude each other on the same lock directory.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent
LIBS = {provider: Path(os.environ.get("LOCK_TEST_" + provider.upper() + "_LIB",
                                      ROOT / prefix / "session-chat/scripts/lib.sh"))
        for provider, prefix in (("claude", "plugins"), ("codex", "codex/plugins"))}

# acquire/release $LOCK in either provider's lib. Defined after the lib is
# sourced, with the lib path in $1 and the provider in $2.
LOCK_FUNCTIONS = '''
acquire() {
  if [ "$2" = codex ]; then acquire_send_lock "$LOCK" "queue:recipient"; else acquire_lock "queue:recipient" "$LOCK"; fi
}
release() {
  if [ "$2" = codex ]; then release_send_lock "$LOCK"; else release_lock "queue:recipient" "$LOCK"; fi
}
'''

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
RACE_LOSING_MKDIR = '''mkdir() { for last in "$@"; do :; done; command mkdir "$@" 2>/dev/null || [ -d "$last" ]; }'''

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
           if not k.startswith(("SESSION_", "CLAUDE_", "CODEX_", "TMUX"))}
    env.update(HOME=directory, TMPDIR=directory,
               SESSION_CHAT_TARGET_MESSAGES_DIR=str(Path(directory) / "messages"))
    env.update(extra)
    return env


def make_store(directory):
    """The private queue/.locks directory both libs expect, and its lock path."""
    locks = Path(directory) / "messages" / "queue" / ".locks"
    locks.mkdir(parents=True)
    for path in (locks, locks.parent, locks.parent.parent):
        path.chmod(0o700)
    return locks, locks / "recipient.lock"


class LockTests(unittest.TestCase):
    def test_both_libs_use_one_queue_lock_path(self):
        with tempfile.TemporaryDirectory(prefix="session-chat-lock-path-") as directory:
            env = clean_env(directory)
            paths = {provider: subprocess.run(
                ["bash", "-c", 'source "$1"; queue_lock_path recipient', "path", str(lib)],
                env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, check=True,
            ).stdout.strip() for provider, lib in LIBS.items()}
            self.assertEqual(paths["claude"], paths["codex"])
            self.assertEqual(paths["claude"], str(Path(directory) / "messages/queue/.locks/recipient.lock"))

    def test_mixed_provider_contention(self):
        for mkdir in ("system", "uutils"):
            with self.subTest(mkdir=mkdir):
                self.run_contention(uutils_mkdir=mkdir == "uutils")

    def run_contention(self, uutils_mkdir):
        with tempfile.TemporaryDirectory(prefix="session-chat-lock-contention-") as directory:
            root = Path(directory)
            locks, lock = make_store(directory)
            env = clean_env(directory, LOCK=str(lock), WORK=directory,
                            SESSION_CHAT_LOCK_TIMEOUT_MS="30000")
            if uutils_mkdir:
                env["PATH"] = str(install_uutils_mkdir(directory)) + os.pathsep + env["PATH"]
            (root / "count").write_text("0\n")
            # Each critical section runs in its own short-lived process, like a
            # send-message.sh call: it exits as soon as it releases and is
            # reaped at once, so a waiter that read its pid just before the
            # release sees a dead holder while the next sender holds the lock.
            # The overlap probe is an O_EXCL create, so it does not depend on
            # the mkdir under test.
            holder = '''
set -u
source "$1"
''' + LOCK_FUNCTIONS + '''
acquire "$@" || exit 1
( set -o noclobber; : > "$WORK/exclusive" ) 2>/dev/null || { echo "two holders at once" >&2; exit 2; }
read -r count < "$WORK/count"
sleep 0.005
printf '%s\\n' "$((count+1))" > "$WORK/count"
rm "$WORK/exclusive" || exit 3
release "$@"
'''
            writer = '''
for iteration in 1 2 3; do
  bash -c "$HOLDER" holder "$1" "$2" || exit "$?"
done
'''
            env["HOLDER"] = holder
            processes = []
            for index in range(12):
                provider = "codex" if index % 2 else "claude"
                processes.append(subprocess.Popen(["bash", "-c", writer, "writer", str(LIBS[provider]), provider],
                                                  env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True))
            try:
                results = [(p, p.communicate(timeout=90)) for p in processes]
                # Report every failed writer. A writer that exits while holding
                # the lock strands it for the others, so the root cause can be in
                # any of them.
                failures = ["writer %d exited %d: %s" % (index, p.returncode, (stdout + stderr).strip())
                            for index, (p, (stdout, stderr)) in enumerate(results) if p.returncode]
                self.assertEqual(failures, [], "\n".join(failures))
                self.assertEqual((root / "count").read_text().strip(), "36")
                self.assertEqual(list(locks.iterdir()), [])
            finally:
                for p in processes:
                    if p.poll() is None:
                        p.kill()
                        p.communicate()

    def run_case(self, provider, body, env_extra=None):
        """Run body in a shell that has sourced the provider's lib, with $LOCK set."""
        with tempfile.TemporaryDirectory(prefix="session-chat-lock-case-") as directory:
            _, lock = make_store(directory)
            env = clean_env(directory, LOCK=str(lock), **(env_extra or {}))
            script = 'set -u\nsource "$1"\n' + LOCK_FUNCTIONS + body
            result = subprocess.run(["bash", "-c", script, "case", str(LIBS[provider]), provider],
                                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                    timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_mkdir_success_does_not_prove_ownership(self):
        # A second process whose mkdir loses the create race but still exits 0
        # must not take a held lock, from either provider against either.
        for holder in ("claude", "codex"):
            for second in ("claude", "codex"):
                with self.subTest(holder=holder, second=second):
                    self.run_case(holder, '''
acquire "$@" || exit 1
if SESSION_CHAT_LOCK_TIMEOUT_MS=300 bash -c '
  source "$1"
  ''' + RACE_LOSING_MKDIR + LOCK_FUNCTIONS + '''
  acquire "$@"
' second-writer "$SECOND_LIB" "$SECOND" 2>/dev/null; then
  echo "a second process acquired a held lock" >&2; exit 1
fi
[ "$(cat "$LOCK/pid")" = "$$" ] || { echo "the holder pid was overwritten" >&2; exit 1; }
release "$@"
[ ! -e "$LOCK" ]
''', env_extra={"SECOND_LIB": str(LIBS[second]), "SECOND": second})

    def test_race_losing_mkdir_still_acquires_a_free_lock(self):
        # The fix must not turn a lying mkdir into a lock nobody can take.
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, RACE_LOSING_MKDIR + '''
SESSION_CHAT_LOCK_TIMEOUT_MS=1000
acquire "$@" || exit 1
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
release "$@"
[ ! -e "$LOCK" ]
''')

    def test_stale_lock_is_taken_over(self):
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
command mkdir "$LOCK"
printf '%s\\n' "$dead" > "$LOCK/pid"
SESSION_CHAT_LOCK_TIMEOUT_MS=1000
acquire "$@" || exit 1
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 2
[ ! -e "$LOCK/reclaim" ] || exit 3
release "$@"
[ ! -e "$LOCK" ]
''')

    def test_stale_reclaim_never_touches_a_newer_holder(self):
        # A waiter read a pid, and that holder released and exited before the
        # waiter checked it. Another sender holds the lock now. The waiter's
        # takeover must fail and leave the new holder's lock alone; the old
        # protocol deleted it, which gave the lock two holders.
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
acquire "$@" || exit 1
if _session_chat_reclaim_lock "$LOCK" "$dead"; then
  echo "took over a lock held by a live process" >&2; exit 1
fi
[ "$(cat "$LOCK/pid")" = "$$" ] || { echo "the holder pid was overwritten" >&2; exit 2; }
[ ! -e "$LOCK/reclaim" ] || exit 3
release "$@"
[ ! -e "$LOCK" ]
''')

    def test_reclaim_marker_is_exclusive(self):
        # Two waiters that saw the same dead pid: only the one that creates the
        # marker takes over, and it never removes another reclaimer's marker.
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, DEAD_PID + '''
command mkdir "$LOCK"
printf '%s\\n' "$dead" > "$LOCK/pid"
: > "$LOCK/reclaim"
if _session_chat_reclaim_lock "$LOCK" "$dead"; then
  echo "reclaimed past an in-flight marker" >&2; exit 1
fi
[ "$(cat "$LOCK/pid")" = "$dead" ] || exit 2
[ -e "$LOCK/reclaim" ] || { echo "removed another reclaimer's marker" >&2; exit 3; }
rm -f "$LOCK/reclaim"
_session_chat_reclaim_lock "$LOCK" "$dead" || exit 4
[ "$(cat "$LOCK/pid")" = "$$" ] || exit 5
[ ! -e "$LOCK/reclaim" ] || exit 6
release "$@"
[ ! -e "$LOCK" ]
''')

    def test_release_with_inflight_marker_leaves_no_ownerless_lock(self):
        # A waiter's reclaim marker can sit in the directory while the holder
        # releases. A pid-then-rmdir release fails its rmdir and strands a
        # directory with no holder, which every later sender waits on.
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
acquire "$@" || exit 1
: > "$LOCK/reclaim"
release "$@"
[ ! -e "$LOCK" ] || { echo "release left $(ls -A "$LOCK" | tr '\\n' ' ')behind" >&2; exit 1; }
[ -z "$(ls -A "$(dirname "$LOCK")")" ] || { echo "release left a retirement directory" >&2; exit 2; }
''')

    def test_release_by_a_non_holder_keeps_the_lock(self):
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
command mkdir "$LOCK"
printf '%s\\n' "$PPID" > "$LOCK/pid"
release "$@"
[ "$(cat "$LOCK/pid")" = "$PPID" ] || { echo "released a lock held by another process" >&2; exit 1; }
''')

    @unittest.skipIf(hasattr(os, "geteuid") and os.geteuid() == 0, "root ignores directory write permission")
    def test_unwritable_pid_fails_closed_and_cleans_up(self):
        # A lock directory whose pid file cannot be created is not a held lock.
        # The acquirer reports it and removes the empty directory, so it does
        # not strand the lock for every later sender.
        for provider in ("claude", "codex"):
            with self.subTest(provider=provider):
                self.run_case(provider, '''
mkdir() { command mkdir -m 500 "$@"; }
SESSION_CHAT_LOCK_TIMEOUT_MS=1000
if acquire "$@" 2>"$HOME/err"; then echo "acquired a lock without a holder pid" >&2; exit 1; fi
grep -q "holder pid" "$HOME/err" || { cat "$HOME/err" >&2; exit 2; }
[ ! -e "$LOCK" ] || { echo "left the empty lock directory behind" >&2; exit 3; }
''')

    def test_lock_helpers_are_identical_across_providers(self):
        # Both providers share one lock protocol on a recipient's queue lock.
        pattern = re.compile(r"^(_session_chat_(?:claim|reclaim|release)_lock)\(\) ([({])\n.*?^[)}]\n",
                             re.M | re.S)
        bodies = {provider: {m.group(1): m.group(0) for m in pattern.finditer(path.read_text())}
                  for provider, path in LIBS.items()}
        self.assertEqual(sorted(bodies["claude"]), ["_session_chat_claim_lock", "_session_chat_reclaim_lock",
                                                    "_session_chat_release_lock"])
        self.assertEqual(bodies["claude"], bodies["codex"])


if __name__ == "__main__":
    unittest.main()
