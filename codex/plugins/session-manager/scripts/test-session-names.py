#!/usr/bin/env python3
"""End-to-end regression tests for Codex session names and dependent readers."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPTS = Path(__file__).resolve().parent
SESSION_ID = "11111111-1111-4111-8111-111111111111"


def entry(name, stamp="2026-09-16T05:00:00Z"):
    return {"id": SESSION_ID, "thread_name": name, "updated_at": stamp}


class SessionNamesTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="session-names-test.")
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name).resolve()
        self.project = root / "project with spaces"
        self.project.mkdir()
        self.data = root / "codex"
        sessions = self.data / "sessions"
        sessions.mkdir(parents=True)
        messages = [
            {"type": "session_meta", "payload": {"id": SESSION_ID, "cwd": str(self.project)}},
            {"type": "event_msg", "payload": {"type": "user_message", "message": "Original description"}},
        ]
        (sessions / "rollout.jsonl").write_text(
            "\n".join(json.dumps(row, separators=(",", ":")) for row in messages), encoding="utf-8"
        )
        self.index = self.data / "session_index.jsonl"
        self.env = dict(os.environ, CODEX_HOME=str(self.data))
        self.no_jq = root / "no-jq"
        self.no_python = root / "no-python"
        for directory in (self.no_jq, self.no_python):
            directory.mkdir()
            for tool in ("bash", "awk", "cut", "date", "dirname", "find", "grep", "head", "sed", "sort", "stat", "tr", "uname"):
                (directory / tool).symlink_to(shutil.which(tool))
        (self.no_jq / "python3").symlink_to(shutil.which("python3"))
        self.assertIsNone(shutil.which("jq", path=str(self.no_jq)))
        self.assertIsNone(shutil.which("python3", path=str(self.no_python)))

    def run_script(self, script, *args, path=None):
        env = self.env.copy()
        if path is not None:
            env["PATH"] = str(path)
        return subprocess.run(
            ["/bin/bash", str(SCRIPTS / script), *args], env=env,
            cwd=self.project, text=True, capture_output=True, timeout=15,
        )

    def write_index(self, rows):
        self.index.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")

    def test_names_with_and_without_jq(self):
        cases = [
            ("ordinary", [entry("Session name")], "Session name"),
            ("quoted Unicode", [entry('Fix "quotes" — café \\ path')], 'Fix "quotes" — café \\ path'),
            ("field order", [{"updated_at": "2026-09-16T05:00:00Z", "thread_name": "Reordered", "id": SESSION_ID}], "Reordered"),
            ("out of order", [entry("New", "2026-09-16T06:00:00Z"), entry("Old")], "New"),
            ("fraction", [entry("Old"), entry("New", "2026-09-16T05:00:00.500Z")], "New"),
            ("nanoseconds", [entry("Old", "2026-09-16T05:00:00.123456700Z"), entry("New", "2026-09-16T05:00:00.123456701Z")], "New"),
            ("offset", [entry("Old"), entry("New", "2026-09-16T10:30:00.100+05:30")], "New"),
            ("equal instant", [entry("Old"), entry("New", "2026-09-16T05:00:00.000Z")], "New"),
            ("cleared", [entry("Old"), entry("", "2026-09-16T06:00:00Z")], "(untitled)"),
            ("null", [entry(None)], "(untitled)"),
            ("absent name", [{"id": SESSION_ID, "updated_at": "2026-09-16T05:00:00Z"}], "(untitled)"),
            ("blank", [entry(" \t\r\n")], "(untitled)"),
            ("TSV sanitation", [entry("One\tTwo\nThree\rFour")], "One Two Three Four"),
            ("invalid records", [entry("Valid"), 42, None, [], {"id": SESSION_ID, "thread_name": 42}, entry("Bad date", "invalid")], "Valid"),
            ("empty index", [], "(untitled)"),
        ]
        for label, rows, expected in cases:
            self.write_index(rows)
            for path in (None, self.no_jq):
                for script in ("list-sessions.sh", "session-stats.sh"):
                    with self.subTest(case=label, no_jq=path is not None, script=script):
                        result = self.run_script(script, path=path)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stderr, "")
                        if script == "list-sessions.sh":
                            name = result.stdout.splitlines()[0].split("\t")[0]
                        else:
                            name = result.stdout.split("TOP 5 LARGEST SESSIONS\n")[1].splitlines()[-1].split("\t")[2]
                        self.assertEqual(name, expected)
                        self.assertNotIn("Original description", result.stdout)

    def test_partial_row_and_missing_index(self):
        self.write_index([entry("Valid")])
        with self.index.open("a", encoding="utf-8") as stream:
            stream.write('{"id":')
        result = self.run_script("list-sessions.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("Valid\t"))
        self.index.unlink()
        result = self.run_script("list-sessions.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(result.stdout.startswith("(untitled)\t"))

    def test_search_selection_and_project_path(self):
        self.write_index([entry("Renamed session")])
        for path in (None, self.no_jq):
            for script, arg, expected in (
                ("search-sessions.sh", "Renamed session", "Renamed session\t"),
                ("prepare-delete.sh", "Renamed session", "STATUS\tONE\n"),
                ("list-sessions.sh", str(self.project), "Renamed session\t"),
            ):
                with self.subTest(script=script, no_jq=path is not None):
                    result = self.run_script(script, arg, path=path)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertTrue(result.stdout.startswith(expected))
                    self.assertIn(SESSION_ID, result.stdout)

    def test_missing_python_reports_error_through_callers(self):
        self.write_index([entry("Valid")])
        for script, args in (
            ("list-sessions.sh", []), ("session-stats.sh", []),
            ("search-sessions.sh", ["Valid"]),
            ("prepare-delete.sh", ["Valid"]), ("prepare-delete.sh", []),
        ):
            with self.subTest(script=script, args=args):
                result = self.run_script(script, *args, path=self.no_python)
                self.assertEqual(result.returncode, 127)
                self.assertIn("python3 is required", result.stderr)
                self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
