#!/usr/bin/env python3
"""Synthetic routing tests; no live knowledge store or network access."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("evaluation", HERE / "eval-retrieval.py")
EVAL = importlib.util.module_from_spec(spec)
spec.loader.exec_module(EVAL)


class GraphRoutingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.store = self.root / "store"
        self.store.mkdir()

    def seed(self, body, name="seed_note"):
        (self.store / (name + ".md")).write_text("---\nstatus: active\n---\n" + body)

    def plan(self, terms, *args):
        result = subprocess.run(["python3", "-B", str(HERE / "recall-graph.py"),
                                 "--store", str(self.store), "--seed", "seed_note",
                                 "--direct", "seed_note", *args], input=terms,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def test_link_context_and_surface_prefix(self):
        self.seed("Promotion requires [[calendar_note]]. Shipping requires [[blackout_note]].")
        self.assertEqual(self.plan("promote"), "seed_note\tcalendar_note\tpromote~promotion\n")
        self.assertEqual(self.plan("promotion"), "seed_note\tcalendar_note\tpromotion\n")
        self.assertEqual(self.plan("ship"), "")  # Known conservative-filter limitation.

    def test_slug_frontmatter_and_neighboring_sentence_do_not_justify_link(self):
        (self.store / "seed_note.md").write_text(
            "---\nname: renewal\n---\nRenewal is discussed here. Other topic [[renewal_note]].\n"
            "Renewal; supplier questions [[supplier_note]].\n[[renewal_only]]\n")
        self.assertEqual(self.plan("renewal"), "")
        self.seed("Renewal depends on [[calendar_note]].")
        self.assertIn("calendar_note", self.plan("renewal"))

    def test_direct_dedup_canonical_links_and_determinism(self):
        self.seed("Renewal [[seed_note]] [[already_direct]] [[new_note]] [[new_note]] [[Bad-Link]].")
        first = self.plan("renewal", "--direct", "already_direct")
        self.assertEqual(first, "seed_note\tnew_note\trenewal\n")
        self.assertEqual(first, self.plan("renewal", "--direct", "already_direct"))

    def test_unreadable_unsafe_and_oversize_seeds_fail_closed(self):
        target = self.root / "elsewhere.md"
        target.write_text("---\n---\nRenewal [[calendar_note]].")
        path = self.store / "seed_note.md"
        path.symlink_to(target)
        self.assertEqual(self.plan("renewal"), "")
        path.unlink()
        os.mkfifo(path)
        self.assertEqual(self.plan("renewal"), "")
        path.unlink()
        path.write_bytes(b"x" * (1024 * 1024 + 1))
        self.assertEqual(self.plan("renewal"), "")

    def hook_fixture(self):
        def memory(slug, name, body, status="active"):
            return dict(slug=slug, name=name, description=name, tags=[],
                        type="reference", status=status, body=body)
        corpus = {"memories": [
            memory("cedar_renewal", "Cedar renewal", "Renewal requires [[window_note]]. Renewal history [[old_note]].\nSupplier questions [[vendor_note]]."),
            memory("window_note", "Allowed windows", "Use the approved window."),
            memory("old_note", "Previous windows", "Historical record.", "archived"),
            memory("vendor_note", "Supplier address", "Delivery address."),
            memory("incoming_note", "Background notes", "See [[cedar_renewal]]."),
        ]}
        root = self.root / "project"
        root.mkdir()
        return EVAL.materialize(corpus, root)

    def hook(self, store, mode=None, limit=5, scripts=HERE, budget=4000):
        env = EVAL.clean_environment()
        env.update(KNOWLEDGE_MEMORY_HOME=str(store), KNOWLEDGE_AUTO_RECALL="prompt",
                   KNOWLEDGE_AUTO_RECALL_GRAPH="true", KNOWLEDGE_AUTO_RECALL_LIMIT=str(limit),
                   KNOWLEDGE_AUTO_RECALL_BUDGET=str(budget))
        if mode is not None:
            env["KNOWLEDGE_AUTO_RECALL_GRAPH_MODE"] = mode
        result = subprocess.run(["bash", str(scripts / "inject-recall.sh"), "--prompt"],
                                input=json.dumps({"prompt": "renewal"}), text=True,
                                capture_output=True, env=env, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        return result.stdout

    def test_default_selective_filters_inbound_unrelated_and_archived(self):
        store = self.hook_fixture()
        output = self.hook(store)
        self.assertEqual(EVAL.parse_slugs("hook-selective", output), ["cedar_renewal", "window_note"])
        self.assertIn("related via [[cedar_renewal]]; link matched: renewal", output)
        legacy = self.hook(store, "all")
        self.assertIn("incoming_note", legacy)
        self.assertNotEqual(output, legacy)
        self.assertEqual(EVAL.parse_slugs("hook-selective", self.hook(store, "invalid")), ["cedar_renewal"])

    def test_caps_and_missing_planner_preserve_direct_recall(self):
        import shutil
        store = self.hook_fixture()
        self.assertEqual(EVAL.parse_slugs("hook-selective", self.hook(store, limit=1)), ["cedar_renewal"])
        self.assertLessEqual(len(self.hook(store, budget=150).encode()), 150)
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("inject-recall.sh", "memory-search.sh", "search-query.py", "lib.sh", "memory-backlinks.sh"):
            shutil.copy(HERE / name, scripts / name)
        self.assertEqual(EVAL.parse_slugs("hook-selective", self.hook(store, scripts=scripts)), ["cedar_renewal"])

    def test_empty_description_does_not_shift_active_status(self):
        store = self.hook_fixture()
        path = store / "window_note.md"
        path.write_text(path.read_text().replace('description: "Allowed windows"', 'description: ""'))
        output = self.hook(store)
        self.assertIn("- [window_note] (reference, active) —  (related via [[cedar_renewal]]", output)

    def test_no_plan_skips_graph_scan(self):
        import shutil
        store = self.hook_fixture()
        (store / "cedar_renewal.md").write_text("---\nname: Cedar renewal\ndescription: Cedar renewal\nstatus: active\n---\nSupplier questions [[vendor_note]].\n")
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("inject-recall.sh", "memory-search.sh", "search-query.py", "recall-graph.py", "lib.sh"):
            shutil.copy(HERE / name, scripts / name)
        marker = self.root / "graph_called"
        (scripts / "memory-backlinks.sh").write_text("#!/bin/bash\ntouch '" + str(marker) + "'\nexit 1\n")
        self.hook(store, scripts=scripts)
        self.assertFalse(marker.exists())
        self.hook(store, "all", scripts=scripts)
        self.assertTrue(marker.exists())  # Control: legacy expansion calls the scanner.


if __name__ == "__main__":
    unittest.main()
