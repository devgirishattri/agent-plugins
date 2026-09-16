#!/usr/bin/env python3
"""Hermetic CLI tests for local evidence verification; no real stores or remotes."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("handoff", HERE / "handoff-data.py")
schema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(schema)


class VerifyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.repo = self.base / "repo"
        self.repo.mkdir()
        self.store = self.base / "contexts"
        self.store.mkdir(mode=0o700)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "KNOWLEDGE_", "SESSION_CONTEXT_"))}
        self.env.update(SESSION_CONTEXT_HOME=str(self.store), GIT_CONFIG_NOSYSTEM="1",
                        GIT_CONFIG_GLOBAL=os.devnull)
        self.git("init", "-q")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        (self.repo / "file.txt").write_text("one\n")
        (self.repo / "sub").mkdir()
        self.git("add", "file.txt")
        self.git("commit", "-qm", "initial")
        self.sha = self.git("rev-parse", "HEAD").stdout.strip()

    def git(self, *args):
        return subprocess.run(["git", "-C", str(self.repo), *args], env=self.env,
                              capture_output=True, text=True, check=True)

    def save(self, evidence=None, status="done", paths=None):
        if evidence is None:
            evidence = [("file", "file.txt"), ("commit", self.sha)]
        data = {"scope": {"repository": "project_a", "paths": paths or ["."]},
                "items": [{"id": "item_a", "summary": "A claim", "status": status,
                           "evidence": [{"kind": kind, "ref": ref,
                                         "observed_at": "2026-09-16T10:00:00Z"}
                                        for kind, ref in evidence]}]}
        text = "---\nhandoff_version: 2\nkind: handoff\n"
        text += "created: 2026-09-16T10:00:00Z\nupdated: 2026-09-16T10:00:00Z\nexpires: 2026-09-23T10:00:00Z\n"
        text += "\n".join(schema.render(data)) + "\n---\nBody\n"
        (self.store / "arc.md").write_text(text)

    def run_verify(self, *args, env=None):
        return subprocess.run(["bash", str(HERE / "verify-context.sh"), "arc",
                               "--repository-id", "project_a", "--repo", str(self.repo),
                               "--json", *args], env=env or self.env,
                              capture_output=True, text=True, timeout=20)

    def report(self, expected, *args):
        result = self.run_verify(*args)
        self.assertEqual(result.returncode, expected, result.stderr + result.stdout)
        return json.loads(result.stdout)

    def test_verified_files_commits_subdirectory_and_detached_head(self):
        self.save()
        self.git("checkout", "--detach", "-q", self.sha)
        report = self.report(0, "--repo", str(self.repo / "sub"))
        self.assertEqual(report["head"], self.sha)
        self.assertEqual(report["repository"], str(self.repo.resolve()))
        self.assertEqual(report["summary"]["verified"], 4)

    def test_missing_directory_symlink_and_ancestor_symlink(self):
        (self.repo / "link").symlink_to(self.repo / "file.txt")
        (self.repo / "dirlink").symlink_to(self.repo / "sub", target_is_directory=True)
        self.save([("file", "missing"), ("file", "sub"), ("file", "link"),
                   ("file", "dirlink/child")])
        report = self.report(1)
        self.assertEqual([r["status"] for r in report["checks"][-4:]],
                         ["missing", "mismatch", "unverified", "unverified"])

    def test_scope_missing(self):
        self.save(paths=["absent"])
        self.assertEqual(self.report(1)["checks"][1]["status"], "missing")

    def test_commit_missing_blob_and_divergent(self):
        blob = self.git("rev-parse", "HEAD:file.txt").stdout.strip()
        self.git("commit", "--allow-empty", "-qm", "later")
        other = self.git("rev-parse", "HEAD").stdout.strip()
        self.git("checkout", "--detach", "-q", self.sha)
        self.save([("commit", "a" * 40), ("commit", blob), ("commit", other)])
        self.assertEqual([r["status"] for r in self.report(1)["checks"][-3:]],
                         ["missing", "mismatch", "mismatch"])

    def test_test_and_reference_inert(self):
        marker = self.base / "must_not_exist"
        self.save([("test", f"touch {marker}"), ("reference", "https://example.invalid/test")])
        self.assertEqual(self.report(1)["summary"]["unverified"], 2)
        self.assertFalse(marker.exists())

    def test_empty_evidence(self):
        self.save([], status="pending")
        self.assertEqual(self.report(1)["summary"]["unverified"], 1)

    def test_binding_schema_legacy_and_absent_inputs(self):
        self.save()
        self.assertEqual(self.run_verify("--repository-id", "wrong").returncode, 2)
        for text in ["plain\n", "---\nhandoff_version: 1\nkind: handoff\n---\n", "---\nhandoff_version: 99\n---\n"]:
            (self.store / "arc.md").write_text(text)
            result = self.run_verify()
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
        (self.store / "arc.md").unlink()
        self.assertEqual(self.run_verify().returncode, 2)

    def test_unsafe_store_symlinks_and_missing_environment(self):
        self.save()
        (self.store / "unexpected").mkdir()
        self.assertEqual(self.run_verify().returncode, 2)
        (self.store / "unexpected").rmdir()
        target = self.base / "target.md"
        (self.store / "arc.md").rename(target)
        (self.store / "arc.md").symlink_to(target)
        self.assertEqual(self.run_verify().returncode, 2)
        env = dict(self.env)
        del env["SESSION_CONTEXT_HOME"]
        self.assertEqual(self.run_verify(env=env).returncode, 2)

    def test_git_environment_redirects_ignored(self):
        self.save()
        env = dict(self.env, GIT_DIR=str(self.base / "absent"), GIT_WORK_TREE="/",
                   GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="alias.rev-parse",
                   GIT_CONFIG_VALUE_0="!exit 99")
        self.assertEqual(self.run_verify(env=env).returncode, 0)

    def test_unborn_head_and_non_repository(self):
        self.save()
        self.git("update-ref", "-d", "HEAD")
        report = self.report(1)
        self.assertIsNone(report["head"])
        self.assertEqual(report["checks"][-1]["status"], "unverified")
        self.assertEqual(self.run_verify("--repo", str(self.store)).returncode, 2)

    def test_shallow_missing_history(self):
        self.git("commit", "--allow-empty", "-qm", "later")
        original = self.repo
        shallow = self.base / "shallow"
        subprocess.run(["git", "clone", "-q", "--depth", "1", original.as_uri(), str(shallow)],
                       env=self.env, check=True, capture_output=True)
        self.repo = shallow
        self.save([("commit", self.sha)])
        report = self.report(1)
        self.assertTrue(report["shallow"])
        self.assertEqual(report["checks"][-1]["status"], "unverified")

    def test_read_only_and_deterministic(self):
        self.save()
        def snapshot():
            return {str(p.relative_to(self.base)): (p.stat().st_mode, p.stat().st_mtime_ns, p.read_bytes())
                    for p in self.base.rglob("*") if p.is_file()}
        before = snapshot()
        first = self.run_verify()
        second = self.run_verify()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(before, snapshot())


if __name__ == "__main__":
    unittest.main()
