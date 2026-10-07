#!/usr/bin/env python3
"""Real file dispatch -> incoming hint -> strict-v1 decision -> complete read.

Synthetic tmux cat sinks only: no models, consumer workspaces or user stores.
Run from either provider's source tree; the sibling workspace plugin supplies
the validated plan and policy. This is intentionally a cross-plugin contract.
"""
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
WORKSPACE = HERE.parent.parent / 'session-workspace' / 'scripts'


class DispatchRead(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='dispatch-read-', dir='/tmp')
        self.root = Path(self.tmp.name).resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('SESSION_', 'KNOWLEDGE_')) and k not in ('TMUX', 'TMUX_PANE')}
        # The socket is separate from the surrounding plugin suite's server.
        self.socket = str(self.root / 'tmux.sock')
        self.messages = self.root / "it's messages"
        self.messages.mkdir(mode=0o700)
        for name in ('component-a', '.agent-workspace', 'claude-home', 'codex-home'):
            (self.root / name).mkdir()
        cfg = json.loads((WORKSPACE / 'fixtures/valid/harness-v2.json').read_text())
        cfg['stores']['overrides'] = {'messages': str(self.messages)}
        self.config = self.root / '.agent-workspace/workspace.json'
        self.config.write_text(json.dumps(cfg))
        self.master = 'harness-sample-master'
        self.env.update(CLAUDE_HOME=str(self.root / 'claude-home'), CODEX_HOME=str(self.root / 'codex-home'),
                        SESSION_CHAT_TARGET_MESSAGES_DIR=str(self.messages),
                        SESSION_CHAT_ALLOW_SHELL_TARGET='1', SESSION_CHAT_INCOMING_MODE='auto',
                        PLUGIN_ROOT=str(HERE.parent), CLAUDE_PLUGIN_ROOT=str(HERE.parent))
        self.panes = {}
        for index, name in enumerate((self.master, 'harness-sample-component-executor', 'harness-sample-component-reviewer')):
            command = ['new-session', '-d', '-s', 'probe', '-x', '240', '-y', '40'] if index == 0 else ['split-window', '-t', 'probe']
            pane = self.tmux(*command, '-P', '-F', '#{pane_id}', 'cat').stdout.strip()
            self.tmux('set-option', '-p', '-t', pane, '@name', name)
            self.panes[name] = pane
        self.env['TMUX'] = self.tmux('display-message', '-p', '-t', self.panes[self.master], '#{socket_path},#{pid},0').stdout.strip()
        head = b'PROBE-START\nRead the entire task; report the final marker.\n'
        tail = b'\nEND-OF-20K-DISPATCH-PROBE\n'
        self.body = head + b'x' * (20480 - len(head) - len(tail)) + tail
        self.draft = self.messages / 'drafts' / self.master / 'probe.md'
        self.draft.parent.mkdir(parents=True)
        self.draft.write_bytes(self.body)
        self.draft.chmod(0o600)

    def tearDown(self):
        subprocess.run(['tmux', '-S', self.socket, 'kill-server'], env=self.env, capture_output=True)
        self.tmp.cleanup()

    def tmux(self, *args):
        result = subprocess.run(['tmux', '-S', self.socket, *args], env=self.env, capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def probe(self, role, limit):
        name = 'harness-sample-component-' + role
        env = dict(self.env, TMUX_PANE=self.panes[self.master])
        result = subprocess.run(['bash', str(HERE / 'dispatch-to-session.sh'), name, str(self.draft)],
                                env=env, capture_output=True, text=True, timeout=45)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(self.draft.exists(), result.stdout + result.stderr)
        self.assertIn('Removed delivered draft:', result.stdout)
        files = list(self.messages.glob('*-to-' + name + '.md'))
        self.assertEqual(len(files), 1)
        delivered = files[0]
        self.assertEqual(delivered.read_bytes(), self.body)
        uid = re.match(r'^[0-9]+-[0-9]+-([a-f0-9]{8,16})-', delivered.name).group(1)
        prompt = '[from:%s pane:%s msg:%s id:%s] dispatch (20 KB) — read msg file id:%s' % (
            self.master, self.panes[self.master], delivered, uid, uid)
        env.update(TMUX_PANE=self.panes[name], SESSION_CHAT_DISPATCH_INLINE_MAX=str(limit))
        hook = subprocess.run(['bash', str(HERE / 'detect-incoming-message.sh')], env=env,
                              input=json.dumps({'hook_event_name': 'UserPromptSubmit', 'prompt': prompt}),
                              capture_output=True, text=True, timeout=20)
        self.assertEqual(hook.returncode, 0, hook.stderr)
        output = json.loads(hook.stdout)
        text = output.get('systemMessage', output.get('hookSpecificOutput', {}).get('additionalContext', ''))
        header, separator, inline = text.partition('Task content follows:')
        self.assertTrue(separator, text[:500])
        match = re.search(r'Full task read command: (cat [^\n]+)', header)
        self.assertIsNotNone(match, header)
        command = match.group(1).strip()
        self.assertEqual(shlex.split(command), ['cat', str(delivered)])
        self.assertNotIn('END-OF-20K-DISPATCH-PROBE', inline)
        self.assertIn('truncated', inline)
        if limit == 6000:
            self.assertIn('run the cat command above', inline)
        # A real validated plan, not a hand-constructed Context, authorizes the
        # exact command emitted by the incoming hook for this receiving role.
        env.update(SESSION_WORKSPACE_CONFIG=str(self.config), SESSION_WORKSPACE_PROJECT_ROOT=str(self.root),
                   SESSION_WORKSPACE_PANE_NAME=name, SESSION_WORKSPACE_ROLE=role,
                   SESSION_WORKSPACE_PANE_CWD=str(self.root / 'component-a'), SESSION_WORKSPACE_HARNESS_MODE='enforce')
        payload = {'tool_name': 'Bash', 'tool_input': {'command': command}}
        decision = subprocess.run(['python3', '-B', str(WORKSPACE / 'harness-policy.py'), '--decision-json'],
                                  env=env, input=json.dumps(payload), capture_output=True, text=True, timeout=30)
        self.assertEqual(decision.returncode, 0, decision.stderr)
        parsed = json.loads(decision.stdout)
        self.assertEqual((parsed['decision'], parsed['rule']), ('allow', 'coordination.message_read'), parsed)
        read = subprocess.run(['bash', '-c', command], cwd=self.root / 'component-a', env=env,
                              capture_output=True, timeout=10)
        self.assertEqual(read.returncode, 0, read.stderr)
        self.assertEqual(read.stdout, self.body)
        # Negative control: the identical file is not readable as the other
        # receiving role. Its filename identity cannot be borrowed.
        other = 'reviewer' if role == 'executor' else 'executor'
        env.update(SESSION_WORKSPACE_PANE_NAME='harness-sample-component-' + other, SESSION_WORKSPACE_ROLE=other)
        denied = subprocess.run(['python3', '-B', str(WORKSPACE / 'harness-policy.py'), '--decision-json'],
                                env=env, input=json.dumps(payload), capture_output=True, text=True, timeout=30)
        parsed = json.loads(denied.stdout)
        self.assertEqual((parsed['decision'], parsed['rule']), ('deny', 'coordination.message_read'), parsed)

    def test_executor_default_inline_limit(self):
        self.probe('executor', 6000)

    def test_reviewer_default_inline_limit(self):
        self.probe('reviewer', 6000)

    def test_executor_outer_context_limit(self):
        self.probe('executor', 40000)

    def test_reviewer_outer_context_limit(self):
        self.probe('reviewer', 40000)


if __name__ == '__main__':
    unittest.main(verbosity=2)
