#!/usr/bin/env python3
"""Isolated identity regression checks: stub tmux, temporary HOME."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "codex/plugins/session-chat/scripts/auto-name-pane.sh"
SID = "11111111-1111-4111-8111-111111111111"
OTHER = "22222222-2222-4222-8222-222222222222"
class Identity(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = self.bin / "tmux"
        stub.write_text('#!/bin/sh\ncase "$1" in\ndisplay-message) printf "%s" "$FIXTURE_NAME";;\nset-option) printf "%s\\n" "$*" >> "$FIXTURE_LOG";;\nesac\n')
        stub.chmod(0o755)
        self.log = self.root / "log"
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX", "CODEX_"))}
        self.env.update(HOME=str(self.root), CODEX_HOME=str(self.root/"codex"),
                        PATH=str(self.bin)+os.pathsep+os.environ["PATH"], TMUX="fixture",
                        TMUX_PANE="%fixture", FIXTURE_LOG=str(self.log), FIXTURE_NAME="")
        self.hook = dict(session_id=SID, cwd="/fixture/project", transcript_path=None)
    def transcript(self, sid=SID, cwd="/fixture/project", name="Own task", filename=None):
        path = self.root/"codex/sessions"/(filename or f"rollout-date-{sid}.jsonl")
        path.parent.mkdir(parents=True, exist_ok=True)
        rows = [dict(type="session_meta", payload=dict(id=sid,cwd=cwd)),
                dict(type="event_msg",payload=dict(type="user_message",message=name))]
        path.write_text("\n".join(json.dumps(row) for row in rows)+"\n")
        return path
    def run_hook(self, raw=None):
        result = subprocess.run(["bash",str(SCRIPT)], input=raw or json.dumps(self.hook,indent=2),
                                env=self.env,text=True,capture_output=True,check=True)
        self.assertEqual(result.stdout,"")
        return self.log.read_text() if self.log.exists() else ""
    def test_bound_fallback(self):
        self.transcript()
        self.transcript(OTHER,name="Wrong task")
        self.assertIn("@name Own-task",self.run_hook())
    def test_unrelated_only(self):
        self.transcript(OTHER,"/other","Wrong task")
        self.assertEqual(self.run_hook(),"")
    def test_wrong_metadata(self):
        self.hook["transcript_path"]=str(self.transcript(OTHER))
        self.assertEqual(self.run_hook(),"")
    def test_wrong_project(self):
        self.transcript(cwd="/other")
        self.assertEqual(self.run_hook(),"")
    def test_explicit_pretty_json(self):
        self.hook["transcript_path"]=str(self.transcript(filename="explicit.jsonl"))
        self.assertIn("Own-task",self.run_hook())
    def test_manual_name(self):
        self.transcript()
        self.env["FIXTURE_NAME"]="manual"
        self.assertEqual(self.run_hook(),"")
    def test_missing_identity(self):
        self.transcript()
        del self.hook["session_id"]
        self.assertEqual(self.run_hook(),"")
    def test_invalid_json(self):
        self.assertEqual(self.run_hook("{invalid"),"")
    def test_ambiguous(self):
        self.transcript(filename=f"second-{SID}.jsonl")
        self.transcript(name="Second copy")
        self.assertEqual(self.run_hook(),"")
    def test_symlink_explicit(self):
        path=self.transcript()
        link=self.root/"alias"
        link.symlink_to(path.parent, target_is_directory=True)
        self.hook["transcript_path"]=str(link/path.name)
        self.assertIn("Own-task",self.run_hook())
    def test_missing_cwd(self):
        self.transcript()
        del self.hook["cwd"]
        self.assertEqual(self.run_hook(),"")
    def test_relative_cwd(self):
        self.transcript()
        self.hook["cwd"]="relative"
        self.assertEqual(self.run_hook(),"")
    def test_bad_id(self):
        self.transcript()
        self.hook["session_id"]="not-a-uuid"
        self.assertEqual(self.run_hook(),"")
    def test_manual_name_race(self):
        self.transcript()
        stub=self.bin/"tmux"
        stub.write_text('#!/bin/sh\ncase "$1" in\ndisplay-message) if [ -f "$FIXTURE_LOG.count" ]; then printf manual; else touch "$FIXTURE_LOG.count"; fi;;\nset-option) printf "%s\\n" "$*" >> "$FIXTURE_LOG";;\nesac\n')
        self.assertEqual(self.run_hook(),"")
    def test_lagging_empty_transcript(self):
        self.transcript().write_text("")
        self.assertEqual(self.run_hook(),"")
if __name__=="__main__":
    unittest.main()
