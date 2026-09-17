#!/usr/bin/env python3
"""Deterministic context-lock turnover and unsafe-path controls."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


class ContextLockTests(unittest.TestCase):
    def test_release_between_safety_checks_and_unsafe_controls(self):
        for provider, tree in (("codex", "codex/plugins"), ("claude", "plugins")):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as directory:
                library = os.environ.get("CONTEXT_LOCK_TEST_" + provider.upper() + "_LIB",
                                         str(ROOT / tree / "knowledge/scripts/lib.sh"))
                env = {k: v for k, v in os.environ.items()
                       if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX"))}
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
                result = subprocess.run(["bash", "-c", script, "context-lock-test", library, directory],
                                        env=env, capture_output=True, text=True, timeout=15)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
