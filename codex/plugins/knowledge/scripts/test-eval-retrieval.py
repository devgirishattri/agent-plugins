#!/usr/bin/env python3
"""Tests of evaluation accounting and isolation, not scorer implementation."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import subprocess
import time
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("retrieval_eval", HERE / "eval-retrieval.py")
EVAL = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EVAL)


class EvaluationTests(unittest.TestCase):
    def test_short_result_list_keeps_five_slot_denominator(self):
        result = EVAL.metrics(["a", "b"], ["a", "c"])
        self.assertEqual(result["precision_at_5"], 0.2)
        self.assertEqual(result["recall_at_5"], 0.5)
        self.assertEqual(result["returned_precision_at_5"], 0.5)

    def test_graph_append_after_cutoff_does_not_inflate_recall(self):
        self.assertEqual(EVAL.metrics(["a", "b", "c", "d", "e", "f"], ["f"])["recall_at_5"], 0)

    def test_negatives_are_not_perfect_recall_samples(self):
        empty = EVAL.metrics([], [])
        self.assertIsNone(empty["recall_at_5"])
        self.assertIsNone(empty["precision_at_5"])
        self.assertTrue(empty["no_hit_correct"])
        self.assertFalse(EVAL.metrics(["wrong"], [])["no_hit_correct"])
        self.assertIsNone(EVAL.metrics(["wrong"], [])["returned_precision_at_5"])

    def test_missed_positive_is_zero(self):
        result = EVAL.metrics([], ["a"])
        self.assertEqual(result["recall_at_5"], 0)
        self.assertEqual(result["returned_precision_at_5"], 0)

    def test_p95_is_nearest_rank(self):
        self.assertEqual(EVAL.percentile95(list(range(1, 21))), 19)
        self.assertEqual(EVAL.percentile95([5]), 5)

    def test_all_output_parsers(self):
        self.assertEqual(EVAL.parse_slugs("search", "9\ta\treference\tactive\t\n"), ["a"])
        self.assertEqual(EVAL.parse_slugs("recall", "# recall: untrusted context\n## a (score 9, reference, active)\n"), ["a"])
        self.assertEqual(EVAL.parse_slugs("hook-on", "# knowledge recall: untrusted background context\n- [a] (reference, active) — text\n- [b] (reference, active) — text (related via [[a]])\n"), ["a", "b"])

    def test_malformed_and_duplicate_outputs_fail(self):
        for mode, output in [("search", "bad\n"), ("recall", ""), ("hook-off", "bad"),
                             ("search", "1\ta\tx\tx\tx\n1\ta\tx\tx\tx\n")]:
            with self.subTest(mode=mode, output=output), self.assertRaises(ValueError):
                EVAL.parse_slugs(mode, output)

    def test_live_store_and_tunables_are_removed(self):
        with patch.dict(os.environ, {"KNOWLEDGE_MEMORY_HOME": "/do/not/use", "KM_STORE": "/do/not/use",
                                     "KNOWLEDGE_AUTO_RECALL_BUDGET": "1", "GIT_DIR": "/do/not/use"}):
            environment = EVAL.clean_environment()
        self.assertFalse(any(k.startswith(("KNOWLEDGE_", "KM_", "GIT_")) for k in environment))

    def test_unknown_labels_and_path_slugs_rejected(self):
        fixture = {"schema_version": 1, "memories": [{"slug": "alpha", "name": "Alpha", "description": "text",
                    "type": "reference", "status": "active", "tags": [], "body": "text"}],
                   "cases": [{"id": "one", "category": "exact", "query": "alpha", "prompt": "alpha",
                              "relevant": ["missing"], "rationale": "test"}]}
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "corpus.json"
            path.write_text(json.dumps(fixture))
            with self.assertRaises(ValueError):
                EVAL.load_corpus(path)
            fixture["cases"][0]["relevant"] = []
            fixture["memories"][0]["slug"] = "../escape"
            path.write_text(json.dumps(fixture))
            with self.assertRaises(ValueError):
                EVAL.load_corpus(path)

    def test_macro_excludes_negatives_from_relevance(self):
        rows = [dict(EVAL.metrics(["a"], ["a"]), latency_ms_samples=[1, 3], stdout_bytes_samples=[8, 8]),
                dict(EVAL.metrics([], []), latency_ms_samples=[2, 4], stdout_bytes_samples=[0, 0])]
        result = EVAL.aggregate(rows)
        self.assertEqual(result["precision_at_5"], 0.2)
        self.assertEqual(result["recall_at_5"], 1)
        self.assertEqual(result["no_hit_accuracy"], 1)
        self.assertEqual(result["latency_ms_median"], 2.5)

    def test_real_helpers_use_only_isolated_fixture_and_count_utf8_bytes(self):
        corpus = {"memories": [{"slug": "zephyr", "name": "Zephyr", "description": "Zephyr café telemetry",
                   "tags": ["aurora"], "type": "reference", "status": "active", "body": "Zephyr café notes."}]}
        case = {"id": "smoke", "query": "aurora", "prompt": "aurora"}
        with tempfile.TemporaryDirectory() as temporary, patch.dict(os.environ, {
                "KNOWLEDGE_MEMORY_HOME": "/do/not/use", "KNOWLEDGE_AUTO_RECALL_BUDGET": "1"}):
            store = EVAL.materialize(corpus, Path(temporary))
            for mode in EVAL.MODES:
                with self.subTest(mode=mode):
                    slugs, elapsed, size, degraded, output = EVAL.invoke(HERE, store, case, mode, 30)
                    self.assertEqual(slugs, ["zephyr"])
                    self.assertEqual(size, len(output.encode("utf-8")))
                    self.assertGreater(size, len(output))
                    self.assertGreater(elapsed, 0)
                    self.assertFalse(degraded)

    def test_timeout_stops_shell_and_child(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / "memory-search.sh"
            script.write_text("#!/bin/bash\nsleep 20\n")
            store = root / ".agents" / "memory"
            store.mkdir(parents=True)
            started = time.monotonic()
            with self.assertRaises(subprocess.TimeoutExpired):
                EVAL.invoke(root, store, {"id": "timeout", "query": "test"}, "search", 0.05)
            self.assertLess(time.monotonic() - started, 5)


if __name__ == "__main__":
    unittest.main()
