#!/usr/bin/env python3
"""Provider-neutral fallback transport fixtures; no real tmux server or messages."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]
STUB=r'''
source "$1"
tmux() {
  case "$1" in
    display-message) printf '%s\n' "$FIXTURE_NAME"; return "$FIXTURE_NAME_RC" ;;
    list-panes) printf '%s\n' "$FIXTURE_PANES"; return "$FIXTURE_LIST_RC" ;;
    send-keys)
      [ "$FIXTURE_SEND_FAIL" = text ] && return 1
      [ "$FIXTURE_SEND_FAIL" = enter ] && [ "${!#}" = Enter ] && return 1
      printf '%s\n' "$*" >> "$FIXTURE_LOG" ;;
    *) return 2 ;;
  esac
}
kc_send_message target hello
'''


class Transport(unittest.TestCase):
    def run_case(self,provider,**overrides):
        with tempfile.TemporaryDirectory() as temp:
            base=Path(temp); log=base/"sent"
            env={k:v for k,v in os.environ.items() if not k.startswith(("SESSION_","KNOWLEDGE_","CODEX_","CLAUDE_","TMUX"))}
            env.update(HOME=temp,CODEX_HOME=str(base/"codex"),TMUX="fixture",TMUX_PANE="%1",
                FIXTURE_NAME="sender",FIXTURE_NAME_RC="0",FIXTURE_LIST_RC="0",
                FIXTURE_PANES="%2 target",FIXTURE_SEND_FAIL="",FIXTURE_LOG=str(log))
            env.update(overrides)
            lib=ROOT/(("codex/" if provider=="codex" else "")+"plugins/knowledge/scripts/lib.sh")
            result=subprocess.run(["bash","-c",STUB,"fixture",str(lib)],env=env,text=True,capture_output=True)
            return result,log.read_text() if log.exists() else ""

    def test_provider_contracts(self):
        for provider in ("claude","codex"):
            with self.subTest(provider=provider):
                result,sent=self.run_case(provider)
                self.assertEqual(result.returncode,0,result.stderr)
                self.assertEqual(len(sent.splitlines()),2)
                self.assertIn("[from:sender pane:%1] hello",sent)
                for changes in ({"FIXTURE_PANES":""},{"FIXTURE_PANES":"%2 target\n%3 target"},
                                {"FIXTURE_NAME":"bad name"},{"FIXTURE_NAME":""},
                                {"FIXTURE_NAME_RC":"1"},{"FIXTURE_LIST_RC":"1"},
                                {"FIXTURE_SEND_FAIL":"text"}):
                    with self.subTest(changes=changes):
                        result,sent=self.run_case(provider,**changes)
                        self.assertNotEqual(result.returncode,0)
                        self.assertEqual(sent,"")
                result,sent=self.run_case(provider,FIXTURE_SEND_FAIL="enter")
                self.assertNotEqual(result.returncode,0)
                self.assertEqual(len(sent.splitlines()),1)

if __name__=="__main__": unittest.main()
