#!/usr/bin/env python3
"""Hermetic deletion regressions; every attack has an independent control.

SESSION_DELETION_TEST_CODEX_ROOT may point at a scratch Codex plugin tree to
demonstrate the same tests against the original implementation. No live daemon
or live stores are used: codex is replaced by a logging WebSocket fixture.
"""
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PLUGINS = Path(os.environ.get("SESSION_DELETION_TEST_CODEX_ROOT", ROOT / "codex/plugins"))
SID = "11111111-1111-4111-8111-111111111111"


class Boundaries(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="delete-boundary-")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.project = self.root / "project-a"
        self.other = self.root / "project-b"
        self.home = self.root / "codex"
        self.messages = self.root / "messages"
        self.bin = self.root / "bin"
        for p in (self.project, self.other, self.home / "sessions", self.messages, self.bin):
            p.mkdir(parents=True)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(("SESSION_", "KNOWLEDGE_")) and k not in ("TMUX", "TMUX_PANE")}
        self.log = self.root / "delete.log"
        self.native = self.root / "native.json"
        self.native.write_text("[]")
        self.env.update(CODEX_HOME=str(self.home), SESSION_CHAT_TARGET_MESSAGES_DIR=str(self.messages),
                        SESSION_MANAGER_BACKEND="auto", SESSION_MANAGER_TEST_LOG=str(self.log),
                        SESSION_MANAGER_TEST_NATIVE_ROWS=str(self.native),
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        fixture = shlex.quote(str(ROOT / "scripts/test-session-metadata.py"))
        python = shlex.quote(sys.executable)
        mock = self.bin / "codex"
        mock.write_text('#!/bin/sh\n'
                        'if [ "$1" = app-server ]; then\n'
                        '  [ "${SESSION_MANAGER_TEST_OFFLINE:-0}" = 1 ] && exit 1\n'
                        f'  [ "$2" = --listen ] && exec {python} -B {fixture} --stdio-fixture sessions\n'
                        f'  exec {python} -B {fixture} --wire-fixture sessions\n'
                        'fi\n'
                        '[ "$1" = delete ] && [ "$2" = --force ] || exit 2\n'
                        'printf "%s\\n" "$3" >> "$SESSION_MANAGER_TEST_LOG"\n')
        mock.chmod(0o700)

    def run_script(self, plugin, script, *args):
        return subprocess.run(["bash", str(PLUGINS / plugin / "scripts" / script), *args],
                              cwd=self.project, env=self.env, capture_output=True, text=True, timeout=30)

    def clean(self, *args):
        return self.run_script("session-chat", "clean-messages.sh", "--older-than", "0s", *args)

    def transcript(self, project):
        # The matching filename makes clear that transcript binding alone is
        # insufficient: its cwd can still lie about the native UUID's project.
        path = self.home / "sessions" / f"rollout-{SID}.jsonl"
        path.write_text(json.dumps({"type": "session_meta", "payload": {"id": SID, "cwd": str(project)}}) + "\n")

    def bulk(self):
        return self.run_script("session-manager", "delete-all-sessions.sh", "--confirmed", str(self.project))

    def assert_no_delete(self):
        self.assertFalse(self.log.exists() and self.log.read_text(), "native delete was invoked")

    def test_cleanup_newline_refuses_and_preserves_victim(self):
        victim = self.project / "0-victim.md"
        victim.write_text("keep")
        hostile = self.messages / "0-a\n0-victim.md"
        hostile.write_text("message")
        result = self.clean("--apply")
        self.assertTrue(victim.exists(), result.stdout + result.stderr)
        self.assertEqual(victim.read_text(), "keep")
        self.assertTrue(hostile.exists())
        self.assertNotEqual(result.returncode, 0)

    def test_cleanup_control_dry_run_then_delete(self):
        normal = self.messages / "1-123-1234abcd-agent-a-to-agent-b.md"
        normal.write_text("message")
        result = self.clean()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(normal.exists())
        result = self.clean("--apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(normal.exists())

    def test_bulk_forged_transcript_offline_refused(self):
        self.transcript(self.project)
        self.native.write_text(json.dumps([dict(id=SID, cwd=str(self.other), updatedAt=1)]))
        self.env["SESSION_MANAGER_TEST_OFFLINE"] = "1"
        result = self.bulk()
        self.assert_no_delete()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native", result.stdout + result.stderr)

    def test_bulk_filesystem_backend_refused(self):
        self.transcript(self.project)
        self.env["SESSION_MANAGER_BACKEND"] = "filesystem"
        result = self.bulk()
        self.assert_no_delete()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("native", result.stdout + result.stderr)

    def test_bulk_rechecks_native_binding_after_enumeration(self):
        # Preflight matches; the binding changes before the mutation check.
        self.transcript(self.project)
        self.native.write_text(json.dumps([dict(id=SID, cwd=str(self.project), updatedAt=1)]))
        changed=self.root / "changed.json"
        changed.write_text(json.dumps([dict(id=SID,cwd=str(self.other),updatedAt=1)]))
        mock = self.bin / "codex"
        code = mock.read_text()
        marker = shlex.quote(str(self.root / "first-proxy"))
        code = code.replace('if [ "$1" = app-server ]; then\n',
                            'if [ "$1" = app-server ]; then\n'
                            f'  if [ -e {marker} ]; then SESSION_MANAGER_TEST_NATIVE_ROWS={shlex.quote(str(changed))}; export SESSION_MANAGER_TEST_NATIVE_ROWS; else : > {marker}; fi\n')
        mock.write_text(code)
        result = self.bulk()
        self.assert_no_delete()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("project", result.stdout + result.stderr)
        self.assertIn(SID + ": native session belongs to a different project", result.stderr)

    def test_bulk_offline_preflight_is_once_before_batch(self):
        self.transcript(self.project)
        second="22222222-2222-4222-8222-222222222222"
        (self.home/"sessions"/f"rollout-{second}.jsonl").write_text(json.dumps({"type":"session_meta","payload":{"id":second,"cwd":str(self.project)}})+"\n")
        self.env["SESSION_MANAGER_TEST_OFFLINE"]="1"
        result=self.bulk()
        self.assertNotEqual(result.returncode,0)
        self.assert_no_delete()
        self.assertEqual(result.stderr.count("bulk deletion requires native metadata"),1)
        self.assertNotIn("Bulk-deleting",result.stdout)

    def test_bulk_file_only_skipped_and_native_control_deleted(self):
        self.transcript(self.project)
        other="22222222-2222-4222-8222-222222222222"
        self.native.write_text(json.dumps([dict(id=other,cwd=str(self.project),updatedAt=1)]))
        result=self.bulk()
        self.assertNotEqual(result.returncode,0)
        self.assertIn("SKIP\t" + SID,result.stdout)
        self.assertIn("filesystem-only",result.stdout)
        self.assertIn("1 processed | 1 fully deleted | 0 with failures | 1 skipped",result.stdout)
        self.assertEqual(self.log.read_text().splitlines(),[other])

    def test_bulk_plan_never_deletes(self):
        self.native.write_text(json.dumps([dict(id=SID,cwd=str(self.project),updatedAt=1)]))
        result=self.run_script("session-manager","delete-all-sessions.sh","--plan",str(self.project))
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn("ELIGIBLE\t"+SID,result.stdout)
        self.assert_no_delete()

    def test_bulk_temporary_connection_control(self):
        self.native.write_text(json.dumps([dict(id=SID,cwd=str(self.project),updatedAt=1)]))
        mock=self.bin/"codex"
        mock.write_text(mock.read_text().replace('if [ "$1" = app-server ]; then\n','if [ "$1" = app-server ]; then\n  [ "$2" = proxy ] && exit 1\n'))
        result=self.bulk()
        self.assertEqual(result.returncode,0,result.stdout+result.stderr)
        self.assertEqual(self.log.read_text().splitlines(),[SID])

    def test_bulk_native_failure_keeps_uuid_and_diagnostic(self):
        self.native.write_text(json.dumps([dict(id=SID,cwd=str(self.project),updatedAt=1)]))
        mock=self.bin/"codex"
        mock.write_text(mock.read_text()+'echo "Error: active writer fixture" >&2\nexit 7\n')
        result=self.bulk()
        self.assertNotEqual(result.returncode,0)
        self.assertIn("active writer fixture",result.stderr)
        self.assertIn("Native deletion failed for "+SID+" (exit 7)",result.stderr)
        self.assertIn("Failed UUID: "+SID,result.stdout)

    def test_bulk_native_control(self):
        self.transcript(self.project)
        self.native.write_text(json.dumps([dict(id=SID, cwd=str(self.project), updatedAt=1)]))
        result = self.bulk()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.log.read_text().splitlines(), [SID])


if __name__ == "__main__":
    unittest.main()
