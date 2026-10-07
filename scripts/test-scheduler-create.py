#!/usr/bin/env python3
"""Task creation: failed randomness, atomic content and cooperating collisions.

SCHEDULER_CREATE_TEST_CLAUDE_SCRIPTS / SCHEDULER_CREATE_TEST_CODEX_SCRIPTS
select complete baseline script directories for original-code evidence.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = {
    p: Path(os.environ.get('SCHEDULER_CREATE_TEST_' + p.upper() + '_SCRIPTS',
                          ROOT / prefix / 'session-scheduler/scripts')).resolve()
    for p, prefix in [('claude', 'plugins'), ('codex', 'codex/plugins')]
}


class Create(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='create-')
        self.root = Path(self.tmp.name).resolve()
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('SESSION_', 'KNOWLEDGE_'))
                    and k not in ('TMUX', 'TMUX_PANE', 'BASH_ENV', 'ENV')}
        self.shim = self.root / 'bin'
        self.shim.mkdir()
        date = self.shim / 'date'
        date.write_text('#!/bin/sh\nif [ "$1" = "+%s" ]; then echo 1700000001; '
                        'else exec ' + shutil.which('date') + ' "$@"; fi\n')
        date.chmod(0o700)

    def tearDown(self):
        self.tmp.cleanup()

    def fixture(self, provider, suffix):
        home = self.root / (provider + '-' + suffix)
        home.mkdir()
        return home, dict(self.env, SESSION_SCHEDULER_HOME=str(home),
                          PATH=str(self.shim) + ':' + self.env['PATH'])

    def od(self, rc):
        file = self.shim / 'od'
        file.write_text('#!/bin/sh\nprintf " ca fe f0 0d\\n"\nexit ' + str(rc) + '\n')
        file.chmod(0o700)

    def create(self, provider, env, name):
        return subprocess.run(['bash', str(SCRIPTS[provider] / 'task-new.sh'), name],
                              env=env, capture_output=True, text=True, timeout=25)

    def task(self, home):
        return home / 'tasks/task-1700000001-cafef00d.json'

    def test_random_source_failure_and_control(self):
        for provider in SCRIPTS:
            with self.subTest(provider=provider):
                home, env = self.fixture(provider, 'random')
                self.od(1)
                result = self.create(provider, env, 'must-not-create')
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertFalse(list((home / 'tasks').glob('*.json')))
                generator = 'generate_task_id' if provider == 'claude' else 'generate_id'
                direct = subprocess.run(['bash', '-c', 'source "$1"; ' + generator,
                                         'generator', str(SCRIPTS[provider] / 'lib.sh')],
                                        env=env, capture_output=True, text=True, timeout=10)
                self.assertNotEqual(direct.returncode, 0)
                self.assertEqual(direct.stdout, '')
                self.od(0)
                control = self.create(provider, env, 'control')
                self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
                self.assertEqual(json.loads(self.task(home).read_text())['name'], 'control')

    def test_collisions_preserve_every_existing_target(self):
        self.od(0)
        for provider in SCRIPTS:
            for kind in ('file', 'symlink', 'directory'):
                with self.subTest(provider=provider, kind=kind):
                    home, env = self.fixture(provider, kind)
                    file = self.task(home)
                    file.parent.mkdir()
                    victim = home / 'absent-victim'
                    if kind == 'file':
                        file.write_text('sentinel')
                    elif kind == 'symlink':
                        file.symlink_to(victim)
                    else:
                        file.mkdir()
                    result = self.create(provider, env, 'collision')
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertNotIn('Created task', result.stdout)
                    self.assertEqual(list(file.parent.glob('*.tmp.*')), [])
                    self.assertFalse((home / 'locks' / (file.stem + '.lock')).exists())
                    if kind == 'file':
                        self.assertEqual(file.read_text(), 'sentinel')
                        file.unlink()
                    elif kind == 'symlink':
                        self.assertTrue(file.is_symlink())
                        self.assertFalse(victim.exists())
                        file.unlink()
                    else:
                        self.assertEqual(list(file.iterdir()), [])
                        file.rmdir()
                    control = self.create(provider, env, 'control')
                    self.assertEqual(control.returncode, 0, control.stdout + control.stderr)
                    self.assertEqual(json.loads(file.read_text())['name'], 'control')
                    self.assertEqual(file.stat().st_nlink, 1)
                    self.assertEqual(list(file.parent.glob('*.tmp.*')), [])

    def test_concurrent_cross_provider_creators_have_one_winner(self):
        self.od(0)
        home, env = self.fixture('shared', 'race')
        processes = [(provider, subprocess.Popen(['bash', str(scripts / 'task-new.sh'), provider],
                                                 env=env, stdout=subprocess.PIPE,
                                                 stderr=subprocess.PIPE, text=True))
                     for provider, scripts in SCRIPTS.items()]
        results = [(provider, process.communicate(timeout=25), process.returncode)
                   for provider, process in processes]
        winners = [provider for provider, _, rc in results if rc == 0]
        self.assertEqual(len(winners), 1, results)
        file = self.task(home)
        record = json.loads(file.read_text())
        self.assertEqual(record['name'], winners[0], results)
        self.assertRegex(record['id'], r'^task-[0-9]+-[a-f0-9]{8}$')
        self.assertEqual(file.stat().st_nlink, 1)
        # Exercise the same regular-file guard and Store.read used by contracts,
        # without requiring a verification contract on this ordinary new task.
        for provider, scripts in SCRIPTS.items():
            result = subprocess.run(['python3', '-B', '-c',
                'import runpy,sys; m=runpy.run_path(sys.argv[1]); '
                'assert m["Store"](sys.argv[2]).read()["id"] == sys.argv[2]',
                str(scripts / 'task-contract.py'), record['id']],
                env=env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, (provider, result.stderr))


if __name__ == '__main__':
    unittest.main()
