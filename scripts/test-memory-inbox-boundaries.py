#!/usr/bin/env python3
"""Candidate-parent regressions on both providers; synthetic stores only.

KNOWLEDGE_INBOX_TEST_CODEX_WRITER / KNOWLEDGE_INBOX_TEST_CLAUDE_WRITER can
select original writers in scratch directories with their sibling lib.sh.
Every hostile-parent case has normal-directory apply/recovery controls.
"""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
CID = "a" * 64
MEMORY = """---
schema_version: 1
name: Synthetic candidate
description: Synthetic inbox boundary fixture
metadata:
  type: project
created: 2026-01-01
updated: 2026-01-01
---
**Why:** Exercise the writer boundary.

**How to apply:** Use an isolated store.
"""


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class InboxBoundaryTests:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="inbox-boundary-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("KNOWLEDGE_", "SESSION_"))
                    and k not in ("TMUX", "TMUX_PANE")}
        self.env["KNOWLEDGE_PANE_NAME"] = "test-executor"
        subprocess.run(["git", "init", "-q", str(self.project)], check=True,
                       env=self.env, capture_output=True)
        (self.project / ".gitignore").write_text(".agents/memory/\n")
        self.store = self.project / ".agents/memory"
        self.ok(self.run_writer("bootstrap", "--store", self.store))
        self.inbox = self.store / ".inbox"
        self.inbox.mkdir(mode=0o700)
        self.candidate = self.inbox / (CID + ".md")
        self.candidate.write_text("Synthetic candidate content\n")
        self.candidate.chmod(0o600)
        self.candidate_hash = sha(self.candidate)
        self.before_index = (self.store / "MEMORY.md").read_bytes()
        self.staged = self.root / "target.md"
        self.staged.write_text(MEMORY)
        self.index = self.root / "index.md"
        self.index.write_text("- [Synthetic candidate](synthetic.md) — fixture\n")
        self.external = self.root / "external"

    def run_writer(self, *args, crash=None):
        env = self.env.copy()
        if crash is not None:
            env["KNOWLEDGE_TEST_DIE_AT_STEP"] = str(crash)
        return subprocess.run(["bash", str(self.writer), *map(str, args)],
                              cwd=self.project, env=env, capture_output=True,
                              text=True, timeout=30)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def apply(self, *, crash=None, with_candidate=True):
        args = ["apply", "--store", self.store, "--target", "synthetic.md",
                "--staged-target", self.staged, "--staged-index", self.index,
                "--expect-target", "absent", "--expect-index",
                hashlib.sha256(self.before_index).hexdigest()]
        if with_candidate:
            args += ["--candidate", CID, "--expect-candidate", self.candidate_hash]
        return self.run_writer(*args, crash=crash)

    def recover(self):
        return self.run_writer("index", "--store", self.store,
                               "--staged-index", self.store / "MEMORY.md",
                               "--expect-index", sha(self.store / "MEMORY.md"))

    def interrupt_after_commit(self, step=8):
        result = self.apply(crash=step)
        self.assertEqual(result.returncode, 137, result.stderr)
        self.assertTrue((self.store / ".journal").is_dir())
        self.ok(self.run_writer("unlock", "--store", self.store,
                                "--confirm", self.store))

    def move_inbox(self):
        self.inbox.rename(self.external)
        return self.external / (CID + ".md")

    def assert_no_lock(self):
        self.assertFalse((self.store / ".lock").exists())
        self.assertEqual(list(self.store.glob(".lock.claim.*")), [])

    def assert_clean(self):
        self.assert_no_lock()
        self.assertFalse((self.store / ".journal").exists())
        self.assertEqual(list(self.store.glob(".staged.*")), [])

    def assert_committed(self):
        self.assertEqual((self.store / "synthetic.md").read_bytes(), self.staged.read_bytes())
        self.assertEqual((self.store / "MEMORY.md").read_bytes(), self.index.read_bytes())

    def test_apply_symlink_parent_rejected_before_commit(self):
        victim = self.move_inbox()
        self.inbox.symlink_to(self.external, target_is_directory=True)
        result = self.apply()
        self.assertTrue(victim.exists(), "external candidate was deleted")
        self.assertEqual(sha(victim), self.candidate_hash)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("candidate inbox", result.stderr)
        self.assertFalse((self.store / "synthetic.md").exists())
        self.assertEqual((self.store / "MEMORY.md").read_bytes(), self.before_index)
        self.assertTrue(self.inbox.is_symlink())
        self.assert_clean()

    def test_apply_real_parent_control(self):
        self.ok(self.apply())
        self.assert_committed()
        self.assertFalse(self.candidate.exists())
        self.assertTrue(self.inbox.is_dir())
        self.assert_clean()

    def test_recovery_symlink_parent_preserves_evidence_then_resumes(self):
        self.interrupt_after_commit()
        victim = self.move_inbox()
        self.inbox.symlink_to(self.external, target_is_directory=True)
        meta_before = (self.store / ".journal/meta").read_bytes()
        result = self.recover()
        self.assertTrue(victim.exists(), "recovery deleted external candidate")
        self.assertEqual(sha(victim), self.candidate_hash)
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertIn("candidate inbox", result.stderr)
        self.assertEqual((self.store / ".journal/meta").read_bytes(), meta_before)
        self.assert_committed()
        self.assert_no_lock()
        # Explicit fixture repair, never automatic production recovery.
        self.inbox.unlink()
        self.external.rename(self.inbox)
        self.ok(self.recover())
        self.assertFalse(self.candidate.exists())
        self.assert_committed()
        self.assert_clean()

    def test_recovery_real_parent_control(self):
        self.interrupt_after_commit()
        self.ok(self.recover())
        self.assertFalse(self.candidate.exists())
        self.assert_committed()
        self.assert_clean()

    def test_recovery_dangling_parent_rejected(self):
        self.interrupt_after_commit()
        victim = self.move_inbox()
        self.inbox.symlink_to(self.root / "missing", target_is_directory=True)
        result = self.recover()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertTrue(self.inbox.is_symlink())
        self.assertTrue((self.store / ".journal").is_dir())
        self.assertEqual(sha(victim), self.candidate_hash)
        self.assert_committed()
        self.assert_no_lock()

    def test_recovery_nondirectory_parent_rejected(self):
        self.interrupt_after_commit()
        victim = self.move_inbox()
        self.inbox.write_text("not a directory\n")
        result = self.recover()
        self.assertEqual(result.returncode, 4, result.stderr)
        self.assertEqual(self.inbox.read_text(), "not a directory\n")
        self.assertTrue((self.store / ".journal").is_dir())
        self.assertEqual(sha(victim), self.candidate_hash)
        self.assert_committed()
        self.assert_no_lock()

    def test_recovery_already_consumed_control(self):
        self.interrupt_after_commit(step=9)
        self.assertFalse(self.candidate.exists())
        self.ok(self.recover())
        self.assert_committed()
        self.assert_clean()

    def test_recovery_absent_inbox_control_does_not_create_directory(self):
        self.interrupt_after_commit(step=9)
        self.inbox.rmdir()
        self.ok(self.recover())
        self.assertFalse(self.inbox.exists())
        self.assert_committed()
        self.assert_clean()

    def test_apply_without_candidate_does_not_touch_inbox(self):
        victim = self.move_inbox()
        self.inbox.symlink_to(self.external, target_is_directory=True)
        self.ok(self.apply(with_candidate=False))
        self.assertEqual(sha(victim), self.candidate_hash)
        self.assert_committed()
        self.assert_clean()


for provider, prefix in (("Codex", "codex/plugins"), ("Claude", "plugins")):
    writer = Path(os.environ.get("KNOWLEDGE_INBOX_TEST_" + provider.upper() + "_WRITER",
                                 ROOT / prefix / "knowledge/scripts/memory-write.sh"))
    globals()[provider + "InboxTests"] = type(provider + "InboxTests",
                                               (InboxBoundaryTests, unittest.TestCase),
                                               {"writer": writer})


if __name__ == "__main__":
    unittest.main(verbosity=2)
