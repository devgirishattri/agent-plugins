#!/usr/bin/env python3
"""Retained inbox dispositions, both providers; synthetic stores only.

KNOWLEDGE_DISMISS_TEST_CODEX_SCRIPTS / _CLAUDE_SCRIPTS select a full original
scripts directory for original-code failure evidence, never a lone writer.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class Cases:
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="dismiss-", dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("SESSION_", "KNOWLEDGE_")) and k not in ("TMUX", "TMUX_PANE")}
        self.env.update(KNOWLEDGE_PANE_NAME="test-orchestrator", KNOWLEDGE_CONSOLIDATE_NUDGE="1",
                        KNOWLEDGE_TEST_LOCK_RETRY_MAX="1", KNOWLEDGE_TEST_LOCK_RETRY_DELAY="0")
        self.scripts = Path(os.environ.get("KNOWLEDGE_DISMISS_TEST_" + self.provider.upper() + "_SCRIPTS",
                                         ROOT / self.tree / "knowledge/scripts"))
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, env=self.env)
        (self.root / ".gitignore").write_text(".agents/memory/\n")
        self.store = self.root / ".agents/memory"
        self.env["KNOWLEDGE_MEMORY_HOME"] = str(self.store)
        self.ok(self.writer("bootstrap", "--store", self.store))
        self.index = (self.store / "MEMORY.md").read_bytes()
        self.stage = self.root / "candidate.md"
        self.stage.write_text('''---
source: manual
sensitivity: normal
proposed:
  schema_version: "1"
  name: Synthetic learning
  description: Synthetic retained review candidate
  metadata:
    type: project
---
**Why:** An obsolete candidate must stop nudging after review.

**How to apply:** Retain its content separately from pending candidates.
''')
        result = self.capture()
        self.ok(result)
        self.cid = next(line.split(": ")[1] for line in result.stdout.splitlines() if line.startswith("capture_id:"))
        self.pending = self.store / ".inbox" / (self.cid + ".md")
        self.archive = self.store / ".inbox/.dismissed" / (self.cid + ".md")
        self.raw = self.pending.read_bytes()
        self.expected = sha(self.pending)

    def run_script(self, script, *args, env=None, data=None):
        return subprocess.run(["bash", str(self.scripts / script), *map(str, args)], cwd=self.root,
                              env=env or self.env, input=data, text=True, capture_output=True, timeout=20)

    def writer(self, *args, **kwargs):
        return self.run_script("memory-write.sh", *args, **kwargs)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def capture(self):
        return self.run_script("memory-remember.sh", "--store", self.store, "--staged", self.stage)

    def disposition(self, verb="dismiss", expected=None, **kwargs):
        return self.writer(verb, "--store", self.store, "--candidate", self.cid,
                           "--expect-candidate", expected or self.expected, **kwargs)

    def listing(self, *args):
        r = self.run_script("memory-remember.sh", "--store", self.store, "--list", *args)
        self.ok(r)
        return r.stdout

    def nudge(self, json_mode=False):
        r = self.run_script("nudge-consolidate.sh", *(["--stop-json"] if json_mode else []),
                            data='{"stop_hook_active": false}')
        self.ok(r)
        return r.stdout

    def test_nudge_lifecycle_and_retention(self):
        self.assertIn("pending memory candidate", self.nudge())
        notice = json.loads(self.nudge(True))
        if self.provider == "codex":
            self.assertEqual(notice["decision"], "block")
        else:
            self.assertEqual(notice["hookSpecificOutput"]["hookEventName"], "Stop")
        result = self.disposition()
        # Independent assertions expose persistent nudging on original code,
        # even when that writer does not yet recognize the disposition verb.
        with self.subTest(check="writer"):
            self.ok(result)
        with self.subTest(check="reminder_after_review"):
            self.assertEqual(self.nudge(), "")
        with self.subTest(check="json_after_review"):
            self.assertEqual(self.nudge(True), "")
        if result.returncode:
            return
        self.assertFalse(self.pending.exists())
        self.assertEqual(self.archive.read_bytes(), self.raw)
        self.assertEqual((self.store / "MEMORY.md").read_bytes(), self.index)
        self.assertEqual(self.listing(), "")
        self.assertIn(self.cid, self.listing("--dismissed"))
        self.ok(self.disposition())
        self.ok(self.disposition("restore"))
        self.ok(self.disposition("restore"))
        self.assertEqual(self.pending.read_bytes(), self.raw)
        self.assertFalse(self.archive.exists())
        self.assertIn("pending memory candidate", self.nudge())

    def test_recapture_and_new_content(self):
        self.ok(self.disposition())
        result = self.capture(); self.ok(result)
        self.assertIn("no-op (dismissed)", result.stdout)
        self.assertEqual(self.listing(), "")
        self.stage.write_text(self.stage.read_text() + "\nA new fact.\n")
        self.ok(self.capture())
        self.assertEqual(len(self.listing().splitlines()), 1)
        self.assertIn("1 pending memory candidate", self.nudge())
        self.assertEqual(self.archive.read_bytes(), self.raw)

    def test_cas_roles_flags_and_lock(self):
        self.assertEqual(self.disposition(expected="0" * 64).returncode, 4)
        self.assertEqual(self.disposition(env=dict(self.env, KNOWLEDGE_PANE_NAME="test-reviewer")).returncode, 6)
        self.assertEqual(self.writer("dismiss", "--store", self.store, "--candidate", "../bad",
                                     "--expect-candidate", self.expected).returncode, 2)
        self.assertEqual(self.writer("dismiss", "--store", self.store, "--candidate", self.cid,
                                     "--expect-candidate", self.expected, "--extra", "x").returncode, 2)
        lock = self.store / ".lock"; lock.write_text("synthetic holder\n")
        self.assertEqual(self.disposition().returncode, 5)
        lock.unlink()
        self.assertEqual(self.pending.read_bytes(), self.raw)
        self.ok(self.disposition())
        self.assertEqual(self.disposition(expected="0" * 64).returncode, 4)

    def test_unsafe_archive_parent(self):
        d = self.archive.parent
        outside = self.root / "outside"; outside.mkdir()
        for shape in ("symlink", "file", "mode"):
            with self.subTest(shape=shape):
                if shape == "symlink": d.symlink_to(outside, target_is_directory=True)
                elif shape == "file": d.write_text("block")
                else: d.mkdir(); d.chmod(0o755)
                self.assertEqual(self.disposition().returncode, 4)
                self.assertEqual(self.capture().returncode, 4)
                r = self.run_script("memory-remember.sh", "--store", self.store, "--list", "--dismissed")
                self.assertEqual(r.returncode, 4)
                self.assertEqual(self.pending.read_bytes(), self.raw)
                if shape == "mode": d.rmdir()
                else: d.unlink()
        self.assertEqual(list(outside.iterdir()), [])
        self.ok(self.disposition())

    def test_unsafe_source_and_collision(self):
        backup = self.root / "original"; self.pending.rename(backup)
        for shape in ("symlink", "hardlink", "mode", "fifo"):
            with self.subTest(shape=shape):
                if shape == "symlink": self.pending.symlink_to(backup)
                elif shape == "hardlink": os.link(backup, self.pending)
                elif shape == "mode": shutil.copyfile(backup, self.pending); self.pending.chmod(0o644)
                else: os.mkfifo(self.pending)
                self.assertEqual(self.disposition().returncode, 4)
                self.pending.unlink()
        backup.rename(self.pending)
        self.archive.parent.mkdir(mode=0o700)
        self.archive.write_bytes(self.raw); self.archive.chmod(0o600)
        self.assertEqual(self.disposition().returncode, 4)
        self.assertEqual(self.capture().returncode, 4)
        self.assertEqual(self.pending.read_bytes(), self.raw)
        self.archive.unlink()
        self.ok(self.disposition())
        self.pending.write_bytes(self.raw); self.pending.chmod(0o600)
        self.assertEqual(self.disposition("restore").returncode, 4)

    def test_pending_journal_and_changed_archive(self):
        journal = self.store / ".journal"; journal.mkdir()
        self.assertEqual(self.disposition().returncode, 4)
        journal.rmdir(); self.ok(self.disposition())
        self.archive.write_bytes(self.raw + b"tampered\n")
        self.assertEqual(self.disposition("restore").returncode, 4)
        self.assertEqual(self.capture().returncode, 4)
        self.archive.write_bytes(self.raw)
        self.ok(self.disposition("restore"))

    def test_promotion_requires_restore(self):
        self.ok(self.disposition())
        target = self.root / "memory.md"
        target.write_text('''---
schema_version: 1
name: Synthetic learning
description: Synthetic retained review candidate
metadata:
  type: project
created: 2026-01-01
updated: 2026-01-01
---
**Why:** Test promotion after restoration.
**How to apply:** Use the single writer.
''')
        index = self.root / "index.md"
        index.write_text("- [Synthetic learning](synthetic.md) — fixture\n")
        args = ("apply", "--store", self.store, "--target", "synthetic.md",
                "--staged-target", target, "--staged-index", index,
                "--expect-target", "absent", "--expect-index", sha(self.store / "MEMORY.md"),
                "--candidate", self.cid, "--expect-candidate", self.expected)
        self.assertEqual(self.writer(*args).returncode, 4)
        self.assertEqual(self.archive.read_bytes(), self.raw)
        self.ok(self.disposition("restore"))
        self.ok(self.writer(*args))
        self.assertFalse(self.pending.exists())
        self.assertTrue((self.store / "synthetic.md").is_file())


class Codex(Cases, unittest.TestCase):
    provider = "codex"
    tree = "codex/plugins"


class Claude(Cases, unittest.TestCase):
    provider = "claude"
    tree = "plugins"


if __name__ == "__main__":
    unittest.main(verbosity=2)
