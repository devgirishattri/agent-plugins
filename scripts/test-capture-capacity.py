#!/usr/bin/env python3
"""Race automatic inbox captures through the real writer on both providers."""
import concurrent.futures
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest

ROOT = Path(__file__).resolve().parents[1]


class CaptureCapacity(unittest.TestCase):
    def check_capacity(self, tree, global_cap):
        scripts = ROOT / tree / "knowledge/scripts"
        with tempfile.TemporaryDirectory(prefix="capture-capacity-") as temp:
            repo = Path(temp)
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX", "CLAUDE_CODE_", "CODEX_THREAD_"))}
            env.update(KNOWLEDGE_PANE_NAME="fixture-executor",
                       KNOWLEDGE_TEST_LOCK_RETRY_MAX="200",
                       KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING="1" if global_cap else "20",
                       KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT="20" if global_cap else "1")
            subprocess.run(["git", "init", "-q", str(repo)], env=env, check=True)
            (repo / ".gitignore").write_text(".agents/memory/\n")
            store = repo / ".agents/memory"
            init = subprocess.run(["bash", str(scripts / "memory-write.sh"), "bootstrap",
                                   "--store", str(store)], env=env, capture_output=True, text=True)
            self.assertEqual(init.returncode, 0, init.stderr)
            staged = []
            for i in range(4):
                path = repo / f"candidate-{i}.md"
                path.write_text(f"""---
source: auto_capture
sensitivity: normal
evidence: fixture observed result {i}
proposed:
  schema_version: 1
  name: Concurrent lesson {i}
  description: Independent fixture lesson {i}
  metadata:
    type: project
---
**Why:** verified fixture result.
**How to apply:** preserve the fixture constraint.
""")
                staged.append(path)

            barrier = threading.Barrier(4)

            def capture(i, synchronize=False):
                process_env = dict(env, CODEX_THREAD_ID=f"session-{i}" if global_cap else "session-shared")
                if synchronize:
                    barrier.wait(timeout=15)
                return subprocess.run(["bash", str(scripts / "memory-remember.sh"),
                                       "--store", str(store), "--staged", str(staged[i])],
                                      env=process_env, cwd=repo, capture_output=True, text=True)

            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda i: capture(i, synchronize=True), range(4)))
            # The successful sibling is the positive control: none of these
            # denials can pass just because every process failed to initialize.
            self.assertEqual(sorted(r.returncode for r in results), [0, 7, 7, 7],
                             [(r.returncode, r.stdout, r.stderr) for r in results])
            self.assertEqual(len(list((store / ".inbox").glob("*.md"))), 1)
            for result in results:
                if result.returncode == 7:
                    self.assertIn("MAX_PENDING" if global_cap else "SESSION_LIMIT", result.stderr)
            # Increasing the selected capacity admits one previously refused
            # candidate through the same writer, proving the capacity decision.
            loser = next(i for i, r in enumerate(results) if r.returncode == 7)
            env["KNOWLEDGE_AUTO_CAPTURE_MAX_PENDING" if global_cap else "KNOWLEDGE_AUTO_CAPTURE_SESSION_LIMIT"] = "2"
            admitted = capture(loser)
            self.assertEqual(admitted.returncode, 0, admitted.stderr)
            self.assertEqual(len(list((store / ".inbox").glob("*.md"))), 2)

    def test_global_pending_capacity(self):
        for tree in ("plugins", "codex/plugins"):
            with self.subTest(provider=tree):
                self.check_capacity(tree, True)

    def test_session_pending_capacity(self):
        for tree in ("plugins", "codex/plugins"):
            with self.subTest(provider=tree):
                self.check_capacity(tree, False)


if __name__ == "__main__":
    unittest.main()
