#!/usr/bin/env python3
"""Hermetic cross-store search tests using synthetic local fixtures only."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent


class FindTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("GIT_", "KNOWLEDGE_", "SESSION_CONTEXT_"))}
        subprocess.run(["git", "init", "-q", str(self.root)], env=self.env, check=True)
        self.store = self.root / ".agents/memory"
        self.store.mkdir(parents=True)
        (self.store / "MEMORY.md").write_text("# Memory index\n")
        self.context = self.root / ".tmp/contexts"
        self.context.mkdir(parents=True, mode=0o700)
        self.env["SESSION_CONTEXT_HOME"] = str(self.context)
        (self.root / "docs/decisions").mkdir(parents=True)
        (self.root / "README.md").write_text("# Alpha project\nRetry timeout guidance\n")
        (self.root / "docs/guide.md").write_text("# Alpha guide\nRetry timeout guidance\n")
        (self.root / "docs/decisions/decision.md").write_text("# Alpha decision\n")
        (self.context / "arc.md").write_text("# Alpha session\nRetry timeout guidance\n")
        self.memory("alpha_note", "Alpha note", "Retry timeout guidance")
        self.memory("other_note", "Other note", "Alpha background")

    def memory(self, slug, name, body, store=None):
        (store or self.store).joinpath(slug + ".md").write_text(
            f"---\nschema_version: 1\nname: {name}\ndescription: {body}\nmetadata:\n  type: reference\nstatus: active\n---\n{body}\n")

    def call(self, *args, env=None, cwd=None):
        return subprocess.run(["bash", str(HERE / "find-knowledge.sh"), *args],
                              cwd=cwd or self.root, env=env or self.env,
                              capture_output=True, text=True, timeout=40)

    def report(self, query="alpha", *args, code=0):
        result = self.call("--json", *args, query)
        self.assertEqual(result.returncode, code, result.stderr + result.stdout)
        return json.loads(result.stdout)

    def test_all_sources_labels_and_memory_native_identity(self):
        report = self.report()
        self.assertEqual(set(report["sources"]), {"docs", "memory", "context"})
        native = subprocess.run(["bash", str(HERE / "memory-search.sh"), "--json", "--limit", "10", "alpha"],
                                cwd=self.root, env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(report["sources"]["memory"]["results"], json.loads(native.stdout)["results"])
        self.assertEqual(report["sources"]["memory"]["location"], str(self.store))
        self.assertEqual(report["sources"]["context"]["lifetime"], "ephemeral")
        self.assertEqual(report["sources"]["docs"]["authority"], "human-curated")
        self.assertEqual(report["sources"]["docs"]["results"][1]["kind"], "decision")

    def test_shared_phrase_prefix_and_across_line_and(self):
        for query in ['"retry timeout"', "retr* time*", "alpha guidance"]:
            report = self.report(query)
            self.assertTrue(all(s["results"] for s in report["sources"].values()))
        (self.root / "docs/split.md").write_text("retry\ntimeout\n")
        self.assertTrue(any(r["file"] == "docs/split.md" for r in self.report('"retry timeout"')["sources"]["docs"]["results"]))

    def test_memory_degradation_is_explicit_and_not_applied_to_docs(self):
        report = self.report("alpha unknownword")
        self.assertIn("degraded", report["sources"]["memory"])
        self.assertFalse(report["sources"]["docs"]["results"])
        self.assertFalse(report["sources"]["context"]["results"])

    def test_limits_and_source_selection(self):
        report = self.report("alpha", "--limit", "1")
        self.assertTrue(all(len(s["results"]) == 1 for s in report["sources"].values()))
        self.assertEqual(set(self.report("alpha", "--source", "docs")["sources"]), {"docs"})
        self.assertEqual(self.call("--source", "docs", "--store", str(self.store), "alpha").returncode, 2)

    def test_explicit_store_and_relative_context_from_subdirectory(self):
        alternate = self.root / "alternate"
        alternate.mkdir()
        (alternate / "MEMORY.md").write_text("# Index\n")
        self.memory("alternate_note", "Alpha alternate", "Alpha alternate", alternate)
        env = dict(self.env, SESSION_CONTEXT_HOME="../.tmp/contexts")
        result = self.call("--json", "--store", "../alternate", "alpha", cwd=self.root / "docs", env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["sources"]["memory"]["results"][0]["slug"], "alternate_note")
        self.assertEqual(report["sources"]["context"]["results"][0]["ref"], "arc")
        self.assertEqual(len(report["sources"]["docs"]["results"]), 3)

    def test_unsafe_context_does_not_hide_other_sources(self):
        (self.context / "unexpected").mkdir()
        report = self.report(code=1)
        self.assertEqual(report["sources"]["context"]["state"], "unavailable")
        self.assertTrue(report["sources"]["docs"]["results"])
        self.assertTrue(report["sources"]["memory"]["results"])

    def test_missing_context_environment_and_memory_collision(self):
        env = dict(self.env)
        del env["SESSION_CONTEXT_HOME"]
        result = self.call("--json", "alpha", env=env)
        self.assertEqual(result.returncode, 1)
        self.assertIn("SESSION_CONTEXT_HOME", result.stdout)
        self.memory("collision-a", "Alpha", "Alpha")
        self.memory("collision_a", "Alpha", "Alpha")
        self.assertEqual(self.report(code=1)["sources"]["memory"]["state"], "unavailable")

    def test_hidden_symlink_history_and_foreign_project_not_scanned(self):
        outside = self.root / "outside.md"
        outside.write_text("secretneedle\n")
        (self.root / "docs/link.md").symlink_to(outside)
        (self.root / "docs/.hidden").mkdir()
        (self.root / "docs/.hidden/private.md").write_text("secretneedle\n")
        (self.context / ".history").mkdir(mode=0o700)
        (self.context / ".history/arc.20260101-000000Z.md").write_text("secretneedle\n")
        other = self.root / "other/.tmp/contexts"
        other.mkdir(parents=True)
        (other / "other_arc.md").write_text("secretneedle\n")
        self.assertTrue(all(not s["results"] for s in self.report("secretneedle")["sources"].values()))

    def test_oversize_and_special_files_report_partial(self):
        (self.root / "docs/large.md").write_bytes(b"x" * (1024 * 1024 + 1))
        os.mkfifo(self.root / "docs/pipe.md")
        report = self.report("alpha", "--source", "docs", code=1)
        self.assertIn("2 unreadable", report["sources"]["docs"]["issues"][0])

    def test_context_metadata_and_untrusted_text(self):
        (self.context / "arc.md").write_text("---\nkind: handoff\nhandoff_version: 1\nexpires: 2020-01-01T00:00:00Z\n---\nAlpha\tclaim\x1b[31m\n")
        row = self.report("alpha", "--source", "context")["sources"]["context"]["results"][0]
        self.assertEqual(row["reported_metadata"]["expires"], "2020-01-01T00:00:00Z")
        output = self.call("--source", "context", "alpha").stdout
        self.assertNotIn("\x1b", output)
        self.assertIn("expires=2020", output)
        self.assertIn("Untrusted search results", output)

    def test_zero_hits_bad_queries_and_nonrepo(self):
        self.assertTrue(all(not s["results"] for s in self.report("zzzzmissing")["sources"].values()))
        for args in [("--limit", "0", "alpha"), ('"unbalanced',), ("*",), ("--limit", "51", "alpha")]:
            result = self.call(*args)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
        with tempfile.TemporaryDirectory() as elsewhere:
            self.assertEqual(self.call("alpha", cwd=elsewhere).returncode, 2)

    def test_read_only_and_deterministic(self):
        def state():
            return {str(p.relative_to(self.root)): (p.stat().st_mode, p.stat().st_mtime_ns, p.read_bytes())
                    for p in self.root.rglob("*") if p.is_file()}
        before = state()
        first, second = self.call("--json", "alpha"), self.call("--json", "alpha")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(first.stdout, second.stdout)
        self.assertEqual(before, state())

    def test_global_budget_preserves_a_row_from_each_source(self):
        for i in range(50):
            (self.root / f"docs/doc_{i:02}.md").write_text("alpha " + "界" * 275)
            (self.context / f"arc_{i:02}.md").write_text("alpha " + "界" * 275)
        result = self.call("--json", "--limit", "50", "alpha")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertLessEqual(len(result.stdout.encode()), 65536)
        report = json.loads(result.stdout)
        self.assertTrue(all(s["results"] for s in report["sources"].values()))
        self.assertTrue(any(s["output_omitted"] for s in report["sources"].values()))
        human = self.call("--limit", "50", "alpha")
        self.assertLessEqual(len(human.stdout.encode()), 65536)


if __name__ == "__main__":
    unittest.main()
