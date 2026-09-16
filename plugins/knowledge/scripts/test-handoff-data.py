#!/usr/bin/env python3
"""Handoff v2 schema, transition, and inert-evidence regression tests."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("handoff_data", HERE / "handoff-data.py")
DATA = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(DATA)


def fixture():
    return {"scope": {"repository": "project_a", "paths": ["src", "tests"]},
            "items": [{"id": "retry_fix", "summary": "Repair retry behavior", "status": "in_progress",
                       "evidence": [{"kind": "file", "ref": "src/retry.py", "observed_at": "2026-09-16T10:00:00Z"}]}]}


def saved(data):
    return ("---\nhandoff_version: 2\nkind: handoff\ncreated: 2026-09-16T10:00:00Z\n"
            "updated: 2026-09-16T10:00:00Z\nexpires: 2026-09-30T10:00:00Z\n"
            "tickets:\n  - ext:ABC-123\n" + "\n".join(DATA.render(data)) + "\n---\n# Synthetic handoff\n")


class HandoffDataTests(unittest.TestCase):
    def test_roundtrip_and_canonical_keys(self):
        data = fixture()
        data["items"][0]["summary"] = 'Repair café "retry" behavior'
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "handoff.md"
            path.write_text(saved(data), encoding="utf-8")
            self.assertEqual(DATA.load_saved(path), data)
        reordered = {"items": data["items"], "scope": {"paths": ["src", "tests"], "repository": "project_a"}}
        self.assertEqual(list(DATA.render(data)), list(DATA.render(reordered)))

    def test_all_statuses_and_evidence_kinds(self):
        for status in DATA.STATUSES:
            data = fixture()
            data["items"][0]["status"] = status
            DATA.validate_data(data)
        for kind, ref in [("file", "src/missing.py"), ("commit", "a" * 40), ("commit", "b" * 64),
                          ("test", "bash scripts/test-example.sh"), ("reference", "ext:ABC-123")]:
            data = fixture()
            data["items"][0]["evidence"][0].update(kind=kind, ref=ref)
            DATA.validate_data(data)

    def test_done_requires_recorded_evidence_but_other_statuses_allow_none(self):
        data = fixture()
        data["items"][0]["evidence"] = []
        DATA.validate_data(data)
        data["items"][0]["status"] = "done"
        with self.assertRaisesRegex(ValueError, "requires at least one evidence"):
            DATA.validate_data(data)

    def test_duplicate_ids_and_unknown_fields_fail(self):
        data = fixture()
        data["items"].append(copy.deepcopy(data["items"][0]))
        with self.assertRaisesRegex(ValueError, "unique"):
            DATA.validate_data(data)
        for obj in ("root", "scope", "item", "evidence"):
            data = fixture()
            target = {"root": data, "scope": data["scope"], "item": data["items"][0],
                      "evidence": data["items"][0]["evidence"][0]}[obj]
            target["unexpected"] = True
            with self.subTest(obj=obj), self.assertRaisesRegex(ValueError, "unknown fields"):
                DATA.validate_data(data)

    def test_malformed_required_shapes_fail(self):
        for value in [None, [], {}, {"scope": {}, "items": []}]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                DATA.validate_data(value)
        for key, value in [("id", "unstable-id"), ("summary", ""), ("status", "verified"), ("evidence", {})]:
            data = fixture()
            data["items"][0][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                DATA.validate_data(data)

    def test_paths_are_relative_and_no_parent_traversal(self):
        for path in ["/tmp/file", "../file", "src/../../file", "C:\\file", "https://example.invalid/file", "a\nfile"]:
            data = fixture()
            data["scope"]["paths"] = [path]
            with self.subTest(path=path), self.assertRaises(ValueError):
                DATA.validate_data(data)
            data = fixture()
            data["items"][0]["evidence"][0]["ref"] = path
            with self.subTest(ref=path), self.assertRaises(ValueError):
                DATA.validate_data(data)
        data = fixture()
        data["scope"]["paths"] = ["."]
        DATA.validate_data(data)

    def test_dates_and_full_commit_identifiers(self):
        for date in ["2026-02-30T10:00:00Z", "2026-09-16", "2026-09-16T10:00:00+00:00", "2026-09-16T24:00:00Z"]:
            data = fixture()
            data["items"][0]["evidence"][0]["observed_at"] = date
            with self.subTest(date=date), self.assertRaises(ValueError):
                DATA.validate_data(data)
        data = fixture()
        data["items"][0]["evidence"][0].update(kind="commit", ref="abc1234")
        with self.assertRaisesRegex(ValueError, "full lowercase"):
            DATA.validate_data(data)

    def test_duplicate_json_keys_and_nonfinite_values_fail(self):
        for value in ['{"scope":{},"scope":{}}', '{"items":[{"id":"a","id":"b"}]}', '{"x":NaN}']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                DATA.decode(value)

    def test_single_line_contract_includes_unicode_separators(self):
        for separator in ["\n", "\r", "\t", "\x7f", "\x80", "\x85", "\x9f", "\u2028", "\u2029",
                          "\ud800", "\udfff", "\ufffe", "\uffff"]:
            data = fixture()
            data["items"][0]["summary"] = "first" + separator + "second"
            with self.subTest(separator=repr(separator)), self.assertRaises(ValueError):
                DATA.validate_data(data)

    def test_stable_ids_and_repository_survive_updates(self):
        previous = fixture()
        updated = fixture()
        updated["items"][0].update(status="cancelled", evidence=[])
        updated["scope"]["paths"] = ["."]
        DATA.validate_transition(previous, updated)
        updated["items"][0]["id"] = "renamed"
        with self.assertRaisesRegex(ValueError, "IDs must be retained"):
            DATA.validate_transition(previous, updated)
        updated = fixture()
        updated["scope"]["repository"] = "project_b"
        with self.assertRaisesRegex(ValueError, "cannot change scope.repository"):
            DATA.validate_transition(previous, updated)

    def test_saved_envelope_rejects_missing_duplicate_or_unknown_fields(self):
        valid = saved(fixture())
        for content in [valid.replace("handoff_version: 2", "handoff_version: 99"),
                        valid.replace("kind: handoff", "kind: handoff\nkind: handoff"),
                        valid.replace("items:", "extra:"),
                        valid.replace("expires: 2026-09-30T10:00:00Z\n", ""),
                        valid.replace("\n---\n#", "\n#")]:
            with tempfile.TemporaryDirectory() as temporary:
                path = Path(temporary) / "handoff.md"
                path.write_text(content)
                with self.subTest(content=content[:80]), self.assertRaises(ValueError):
                    DATA.load_saved(path)

    def test_cli_preserves_data_and_never_executes_evidence(self):
        data = fixture()
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "must_not_exist"
            data["items"][0]["evidence"][0].update(kind="test", ref="touch " + str(marker))
            source = root / "data.json"
            source.write_text(json.dumps(data))
            handoff = root / "handoff.md"
            handoff.write_text(saved(data))
            for arguments in [["render", "--data", str(source)], ["render", "--previous", str(handoff)],
                              ["validate", str(handoff), "--summary"]]:
                result = subprocess.run([sys.executable, "-B", str(HERE / "handoff-data.py")] + arguments,
                                        capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(marker.exists())
            self.assertIn("recorded, not verified", result.stdout)
            self.assertEqual(handoff.read_text(), saved(data))

    def test_cli_rejects_symlink_without_writing(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            source = root / "data.json"
            source.write_text(json.dumps(fixture()))
            link = root / "link.json"
            link.symlink_to(source)
            result = subprocess.run([sys.executable, "-B", str(HERE / "handoff-data.py"), "render", "--data", str(link)],
                                    capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(result.stdout, "")
            self.assertEqual(len(result.stderr.splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
