#!/usr/bin/env python3
"""Exercise receipt failure/freshness handling with controlled real subprocesses."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("pilot", Path(__file__).with_name("verify-scheduler-workflow.py"))
pilot = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pilot)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="ve-", dir="/tmp")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "repo"
        (self.repo / "scripts").mkdir(parents=True)
        (self.repo / "scripts/verify-scheduler-workflow.py").write_text("fixture runner identity")
        for name in ("session-scheduler", "session-chat", "knowledge", "chronos",
                     "session-workspace/skills/verification-recipe"):
            (self.repo / "codex/plugins" / name).mkdir(parents=True)
        self.suite = self.repo / "codex/plugins/session-scheduler/scripts/test-session-scheduler.sh"
        self.suite.parent.mkdir()
        self.suite.write_text("echo 'session-scheduler smoke tests: 2 passed, 0 failed'\n")
        self.output = self.repo / ".tmp/evidence"
        # Unit fixture has no Git history. Real file inventories and subprocess
        # execution stay enabled; live pilots exercise actual Git identity.
        identity = patch.object(pilot, "source_identity", lambda repo, provider:
                                {"head": "fixture", "files": pilot.inventory(repo, provider)})
        identity.start()
        self.addCleanup(identity.stop)

    def run_suite(self, timeout=3):
        return pilot.run(self.repo, "codex", self.output, timeout)

    def receipt(self):
        return json.loads((self.output / "manifest.json").read_text())

    def test_healthy_and_stale_source(self):
        self.assertEqual(self.run_suite(), 0)
        self.assertEqual(pilot.check(self.repo, self.output), 0)
        self.suite.write_text("exit 9\n")
        self.assertEqual(pilot.check(self.repo, self.output), 1)

    def test_recipe_changes_invalidate_evidence(self):
        self.assertEqual(self.run_suite(), 0)
        self.assertEqual(pilot.check(self.repo, self.output), 0)
        recipe = self.repo / "codex/plugins/session-workspace/skills/verification-recipe/SKILL.md"
        recipe.write_text("changed verification recipe\n")
        self.assertEqual(pilot.check(self.repo, self.output), 1)

    def test_failed_suite_and_zero_work_never_pass(self):
        self.suite.write_text("echo deliberate-failure; exit 9\n")
        self.assertEqual(self.run_suite(), 1)
        self.assertEqual(self.receipt()["result"], "failed")
        self.assertEqual(self.receipt()["exit_code"], 9)
        self.assertIn("deliberate-failure", (self.output / "output.log").read_text())
        self.assertEqual(pilot.check(self.repo, self.output), 1)
        self.output = self.root / "empty-evidence"
        self.suite.write_text("exit 0\n")
        self.assertEqual(self.run_suite(), 1)
        self.assertEqual(self.receipt()["result"], "inconclusive")

    def test_log_tampering(self):
        self.assertEqual(self.run_suite(), 0)
        self.assertEqual(pilot.check(self.repo, self.output), 0)
        (self.output / "output.log").write_text("invented pass")
        with self.assertRaisesRegex(ValueError, "digest mismatch"):
            pilot.check(self.repo, self.output)

    def test_cli_check_exit_codes(self):
        self.assertEqual(self.run_suite(), 0)
        with patch.object(pilot, "ROOT", self.repo), patch.object(
                sys, "argv", ["pilot", "check", "--output", str(self.output)]):
            self.assertEqual(pilot.main(), 0)
            original = self.suite.read_text()
            self.suite.write_text(original + "# changed\n")
            self.assertEqual(pilot.main(), 1)
            self.suite.write_text(original)
            self.assertEqual(pilot.main(), 0)
            (self.output / "output.log").write_text("altered")
            self.assertEqual(pilot.main(), 2)

    def test_timeout_preserves_output_after_cleanup(self):
        self.suite.write_text('echo "$HOME"; echo before-timeout; sleep 10\n')
        self.assertEqual(self.run_suite(timeout=1), 1)
        self.assertEqual(self.receipt()["result"], "inconclusive")
        self.assertEqual(self.receipt()["reason"], "suite timed out")
        lines = (self.output / "output.log").read_text().splitlines()
        self.assertFalse(Path(lines[0]).exists())
        self.assertIn("before-timeout", lines)

    def test_missing_dependency(self):
        original = pilot.shutil.which
        with patch.object(pilot.shutil, "which", lambda name: None if name == "tmux" else original(name)):
            self.assertEqual(self.run_suite(), 1)
        self.assertEqual(self.receipt()["result"], "blocked")
        self.assertEqual(pilot.check(self.repo, self.output), 1)

    def test_drift_during_run(self):
        self.suite.write_text("echo changed >> codex/plugins/chronos/new-input\n"
                              "echo 'session-scheduler smoke tests: 2 passed, 0 failed'\n")
        self.assertEqual(self.run_suite(), 1)
        self.assertEqual(self.receipt()["reason"], "source changed during verification")

    def test_receipt_symlink_and_overwrite_refused(self):
        self.assertEqual(self.run_suite(), 0)
        with self.assertRaises(FileExistsError):
            self.run_suite()
        manifest = self.output / "manifest.json"
        target = self.root / "saved.json"
        manifest.rename(target)
        manifest.symlink_to(target)
        with self.assertRaisesRegex(ValueError, "regular file"):
            pilot.check(self.repo, self.output)

    def test_environment_isolation(self):
        with patch.dict(os.environ, {"SESSION_SCHEDULER_HOME": "live", "TMUX": "live",
                                     "KNOWLEDGE_MEMORY_HOME": "live", "BASH_ENV": "unsafe"}):
            env = pilot.private_environment(self.root)
        for key in ("SESSION_SCHEDULER_HOME", "TMUX", "KNOWLEDGE_MEMORY_HOME", "BASH_ENV"):
            self.assertNotIn(key, env)
        self.assertEqual(env["HOME"], str(self.root))
        self.assertEqual(env["TMUX_TMPDIR"], str(self.root))


if __name__ == "__main__":
    unittest.main()
