#!/usr/bin/env python3
"""Cross-provider envelope, identity and correlation regressions.

Override CHAT_ENVELOPE_TEST_CLAUDE_SCRIPTS / CHAT_ENVELOPE_TEST_CODEX_SCRIPTS
with complete baseline script directories to test the same assertions there.
All stores are disposable; hook fixtures never contact a real tmux server.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = {
    provider: Path(os.environ.get('CHAT_ENVELOPE_TEST_' + provider.upper() + '_SCRIPTS',
                                 ROOT / prefix / 'session-chat/scripts')).resolve()
    for provider, prefix in [('claude', 'plugins'), ('codex', 'codex/plugins')]
}


class Envelope(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='envlp-', dir='/private/tmp' if Path('/private/tmp').exists() else '/tmp')
        self.root = Path(self.tmp.name)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('SESSION_', 'KNOWLEDGE_'))
                    and k not in ('TMUX', 'TMUX_PANE', 'BASH_ENV', 'ENV')}
        self.env.update(TMPDIR=str(self.root), TMUX_TMPDIR=str(self.root))

    def tearDown(self):
        self.tmp.cleanup()

    def fixture(self, provider, name):
        messages = self.root / provider / name
        messages.mkdir(parents=True, mode=0o700)
        env = dict(self.env, SESSION_CHAT_TARGET_MESSAGES_DIR=str(messages),
                   SESSION_CHAT_PANE_NAME='local', SESSION_CHAT_INCOMING_MODE='auto',
                   PLUGIN_ROOT=str(SCRIPTS[provider].parent),
                   CLAUDE_PLUGIN_ROOT=str(SCRIPTS[provider].parent))
        return messages, env

    def run_shell(self, provider, env, code, *args):
        return subprocess.run(['bash', '-c', 'source "$1"; shift; ' + code,
                               'envelope-test', str(SCRIPTS[provider] / 'lib.sh'), *args],
                              env=env, capture_output=True, text=True, timeout=20)

    def script(self, provider, env, name, *args, input=None):
        return subprocess.run(['bash', str(SCRIPTS[provider] / name), *args], env=env,
                              input=input, capture_output=True, text=True, timeout=20)

    def test_leading_envelope_composition_and_refusal_controls(self):
        cases = [
            ('quoted [re:bbbbbbbb]', '[re:aaaaaaaa] [task:task-1] quoted [re:bbbbbbbb]'),
            ('[re:aaaaaaaa] [re:aaaaaaaa] body', '[re:aaaaaaaa] [task:task-1] body'),
            ('[re:aaaaaaaa] [task:task-1] body', '[re:aaaaaaaa] [task:task-1] body'),
            ('[re:bbbbbbbb] body', None),
            ('[re:aaaaaaaa] [re:bbbbbbbb] body', None),
            ('[task:task-1] [re:aaaaaaaa] body', None),
            ('[task:task-2] body', None),
        ]
        for provider in SCRIPTS:
            _, env = self.fixture(provider, 'compose')
            for body, expected in cases:
                with self.subTest(provider=provider, body=body):
                    result = self.run_shell(provider, env, 'apply_envelope aaaaaaaa task-1 "$1"', body)
                    if expected is None:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, '')
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, expected)

    def test_bounded_files_require_a_decided_envelope(self):
        cases = [('[re:aaaaaaaa]suffix', 13, False),
                 ('[re:aaaaaaaa] body', 14, False),
                 ('[re:aaaaaaaa] body', 15, True),
                 ('[re:aaaaaaaa] [task:' + 'x' * 4200 + '] body', 4096, False),
                 ('[re:aaaaaaaa] ' * 300 + '[re:bbbbbbbb] body', 4096, False),
                 ('[re:aaaaaaaa] [task:one] body', 4096, True),
                 ('body [re:aaaaaaaa]', 4096, False),
                 ('[re:aaaaaaaa]', 4096, True)]
        for provider in SCRIPTS:
            for index, (body, cap, expected) in enumerate(cases):
                with self.subTest(provider=provider, index=index):
                    messages, env = self.fixture(provider, 'cap-' + str(index))
                    file = messages / 'packet.md'
                    file.write_text(body)
                    file.chmod(0o600)
                    env['SESSION_CHAT_REPLY_SCAN_BYTES'] = str(cap)
                    result = self.run_shell(provider, env, 'log_reply_ids_from_file peer "$1" local 1234567890abcdef', str(file))
                    self.assertEqual(result.returncode, 0, result.stderr)
                    ledger = messages / 'replies-log.tsv'
                    rows = ledger.read_text().splitlines() if ledger.exists() else []
                    self.assertEqual(bool(rows), expected, rows)
                    if expected:
                        self.assertEqual(rows[0].split('\t')[1:3], ['aaaaaaaa', 'peer'])
                        self.assertEqual(rows[0].split('\t')[4:], ['local', '1234567890abcdef'])

    def test_hook_identity_and_body_share_the_authoritative_prompt(self):
        for provider in SCRIPTS:
            for dispatch in (False, True):
                for decoy in (False, True):
                    with self.subTest(provider=provider, dispatch=dispatch, decoy=decoy):
                        messages, env = self.fixture(provider, f'hook-{dispatch}-{decoy}')
                        body = '[re:aaaaaaaa] [task:task-1] body [re:bbbbbbbb]'
                        file = messages / '1-123-22222222-peer-to-local.md'
                        file.write_text(body)
                        file.chmod(0o600)
                        field = f' msg:{file}' if dispatch else ''
                        prompt = f'[from:peer pane:%2{field} id:22222222] ' + ('dispatch' if dispatch else body)
                        data = {'metadata': '[from:decoy pane:%1 id:11111111] ignored'} if decoy else {}
                        data.update(hook_event_name='UserPromptSubmit', prompt=prompt)
                        result = self.script(provider, dict(env, TMUX='isolated-hook-fixture'),
                                             'detect-incoming-message.sh', input=json.dumps(data))
                        self.assertEqual(result.returncode, 0, result.stderr)
                        rows = (messages / 'replies-log.tsv').read_text().splitlines()
                        self.assertEqual(len(rows), 1)
                        self.assertEqual(rows[0].split('\t')[1:],
                                         ['aaaaaaaa', 'peer', 'task-1', 'local', '22222222'])
                        self.assertNotIn('decoy', result.stdout)

    def test_reporter_checks_all_senders_recipients_and_tasks(self):
        for provider in SCRIPTS:
            with self.subTest(provider=provider):
                messages, env = self.fixture(provider, 'report')
                ts = str(int(time.time() * 1000))
                sent = messages / 'sent-log.tsv'
                sent.write_text(f'{ts}\taaaaaaaa\tlocal\tpeer\tsend\tlive\trequest\t\n')
                replies = messages / 'replies-log.tsv'
                unexpected = [f'{ts}\taaaaaaaa\tother\tone\tlocal\t11111111',
                              f'{ts}\taaaaaaaa\tpeer\ttwo\tother\t22222222']
                replies.write_text('\n'.join(unexpected) + '\n')
                for file in (sent, replies):
                    file.chmod(0o600)
                pending = self.script(provider, env, 'check-replies.sh', '--pending')
                self.assertEqual(pending.returncode, 0, pending.stderr)
                self.assertIn('unconfirmed', pending.stdout)
                self.assertNotIn('\tverified:', pending.stdout)
                valid = [f'{ts}\taaaaaaaa\tpeer\ttask-{i}\tlocal\t{i:016x}' for i in range(4)]
                replies.write_text('\n'.join(unexpected + valid) + '\n')
                report = self.script(provider, env, 'check-replies.sh')
                self.assertEqual(report.returncode, 0, report.stderr)
                rows = [row.split('\t') for row in report.stdout.splitlines() if '\tverified:' in row]
                self.assertEqual({row[-1] for row in rows}, {'task-' + str(i) for i in range(4)})
                filtered = self.script(provider, env, 'check-replies.sh', '--task', 'task-2')
                self.assertEqual(filtered.returncode, 0, filtered.stderr)
                self.assertEqual(filtered.stdout.count('\tverified:'), 1)
                self.assertIn('\ttask-2\n', filtered.stdout)
                replies.write_text(f'{ts}\taaaaaaaa\tpeer\n')
                legacy = self.script(provider, env, 'check-replies.sh')
                self.assertIn('replied (recipient-unknown):peer', legacy.stdout)
                self.assertNotIn('\tverified:', legacy.stdout)

    def test_generator_checks_od_status_without_pipefail(self):
        for provider in SCRIPTS:
            _, env = self.fixture(provider, 'random')
            for rc in (1, 0):
                with self.subTest(provider=provider, rc=rc):
                    result = self.run_shell(provider, env,
                        'OD_RC="$1"; od() { printf " 01 23 45 67 89 ab cd ef\\n"; return "$OD_RC"; }; generate_id', str(rc))
                    self.assertEqual(result.returncode, rc, result.stderr)
                    self.assertEqual(result.stdout, '' if rc else '0123456789abcdef')

    def test_cleanup_preserves_hexlike_and_numeric_sender_prefixes(self):
        senders = ['worker', 'deadbeef-worker', 'deadbeefdeadbeef-worker', '123-worker']
        for provider in SCRIPTS:
            with self.subTest(provider=provider):
                messages, env = self.fixture(provider, 'filenames')
                files = {}
                for sender in senders:
                    file = messages / f'1-123-0123456789abcdef-{sender}-to-local.md'
                    file.write_text(sender)
                    file.chmod(0o600)
                    files[sender] = file
                if provider == 'claude':
                    listing, cleaning, sender_flag = 'messages-list.sh', 'messages-clean.sh', '--from'
                else:
                    listing, cleaning, sender_flag = 'list-messages.sh', 'clean-messages.sh', '--sender'
                listed = self.script(provider, env, listing, sender_flag, 'worker')
                self.assertEqual(listed.returncode, 0, listed.stderr)
                self.assertIn(files['worker'].name, listed.stdout)
                for sender in senders[1:]:
                    self.assertNotIn(files[sender].name, listed.stdout)
                preview = self.script(provider, env, cleaning, '--older-than', '0', sender_flag, 'worker')
                self.assertEqual(preview.returncode, 0, preview.stderr)
                self.assertTrue(all(file.exists() for file in files.values()))
                applied = self.script(provider, env, cleaning, '--older-than', '0', sender_flag, 'worker', '--apply')
                self.assertEqual(applied.returncode, 0, applied.stderr)
                self.assertFalse(files['worker'].exists())
                for sender in senders[1:]:
                    self.assertEqual(files[sender].read_text(), sender)

    def test_wrappers_fail_closed_and_compose_task_envelopes(self):
        socket = str(self.root / 'tmux.sock')

        def tmux(*args):
            result = subprocess.run(['tmux', '-S', socket, *args], env=self.env,
                                    capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
            return result.stdout.strip()

        try:
            sender = tmux('new-session', '-d', '-s', 'envelope', '-P', '-F', '#{pane_id}', 'cat')
            peer = tmux('split-window', '-t', 'envelope', '-P', '-F', '#{pane_id}', 'cat')
            for pane, name in [(sender, 'local'), (peer, 'peer')]:
                tmux('set-option', '-p', '-t', pane, '@name', name)
            transport = tmux('display-message', '-p', '-t', sender, '#{socket_path},#{pid},0')
            shim = self.root / 'bin'
            shim.mkdir()
            od = shim / 'od'
            od.write_text('#!/bin/sh\nprintf " 01 23 45 67 89 ab cd ef\\n"\nexit 1\n')
            od.chmod(0o700)
            prompt = self.root / 'prompt.md'
            prompt.write_text('body quotes [re:bbbbbbbb]\n')
            for provider in SCRIPTS:
                for script, payload in [('send-message.sh', 'body quotes [re:bbbbbbbb]'),
                                        ('dispatch-to-session.sh', str(prompt))]:
                    with self.subTest(provider=provider, wrapper=script):
                        messages, env = self.fixture(provider, script)
                        env.update(TMUX=transport, TMUX_PANE=sender,
                                   SESSION_CHAT_ALLOW_SHELL_TARGET='1', SESSION_CHAT_SKIP_VERIFY='1',
                                   SESSION_CHAT_SETTLE_MS='0')
                        failed = self.script(provider, dict(env, PATH=str(shim) + ':' + env['PATH']),
                                             script, 'peer', payload)
                        self.assertNotEqual(failed.returncode, 0)
                        self.assertNotIn('Message id:', failed.stdout)
                        self.assertFalse(list(messages.glob('*.md')))
                        self.assertFalse((messages / 'sent-log.tsv').exists())
                        self.assertFalse(list(messages.glob('queue/*.tsv')))
                        control = self.script(provider, env, script, '--reply-to', 'aaaaaaaa',
                                              '--task', 'task-1', 'peer', payload)
                        self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
                        sent = (messages / 'sent-log.tsv').read_text().splitlines()[-1].split('\t')
                        self.assertRegex(sent[1], r'^[a-f0-9]{16}$')
                        self.assertEqual(sent[7], 'task-1')
                        if script == 'dispatch-to-session.sh':
                            self.assertEqual([line for line in control.stdout.splitlines()
                                              if line.startswith('Message id:')], ['Message id: ' + sent[1]])
                            packet, = messages.glob('*.md')
                            self.assertEqual(packet.read_text(),
                                             '[re:aaaaaaaa] [task:task-1] body quotes [re:bbbbbbbb]\n')
        finally:
            subprocess.run(['tmux', '-S', socket, 'kill-server'], env=self.env, capture_output=True)


if __name__ == '__main__':
    unittest.main()
