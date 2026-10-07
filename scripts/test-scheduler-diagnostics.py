#!/usr/bin/env python3
"""Cross-provider diagnostic observations through real scheduler helpers.

Uses the verdict fixture's real ledgers and recording transport. Provider-root
overrides are inherited from test-verdict-events.py for exact baseline overlays.
No native-provider integration or authenticated DIAG framing is claimed.
"""
import importlib.util
import json
from pathlib import Path
import shutil
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('verdict_fixture', ROOT / 'scripts/test-verdict-events.py')
FIXTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FIXTURE)


class Diagnostics(FIXTURE.Verdicts):
    # Inherit fixture methods, not the verdict suite's test methods.
    def records(self, result):
        return [json.loads(line[5:]) for line in result.stderr.splitlines() if line.startswith('DIAG ')]

    def record(self, result, reason):
        rows = [row for row in self.records(result) if row['reason'] == reason]
        self.assertEqual(len(rows), 1, result.stderr)
        row = rows[0]
        self.assertEqual(row['schema'], 'diag/1')
        self.assertEqual(set(row), {'schema', 'emitter', 'helper', 'version', 'subject', 'phase', 'reason',
                                   'outcome', 'state_committed', 'notification', 'task', 'generation',
                                   'event', 'request', 'also', 'also_truncated'})
        if row['notification'] is not None:
            self.assertIn(row['notification']['for'], ['assigner_ack', 'reviewer_request', 'verdict_event'])
        return row

    def mv_failure(self, f, number, after=False):
        real = shutil.which('mv')
        shim = f['base'] / 'bin/mv'
        shim.write_text('''#!/bin/bash
case "$1" in
  *.json.tmp.*)
    n=$(cat "$PROBE_LOG/mvcount" 2>/dev/null || echo 0)
    n=$((n+1)); printf '%s' "$n" > "$PROBE_LOG/mvcount"
    if [ "$n" = "'''+str(number)+'''" ]; then
'''+('''      "'''+real+'''" "$@" || exit $?
      echo published >> "$PROBE_LOG/killed.log"
      kill -KILL $$
''' if after else '      exit 1\n')+'''
    fi ;;
esac
exec "'''+real+'''" "$@"
''')
        shim.chmod(0o700)

    def test_refusal_and_success(self):
        for provider in FIXTURE.PROVIDERS:
            with self.subTest(provider=provider):
                f = self.fixture(provider, 'refusal')
                bad = self.run_helper(f, 'executor', 'task-done.sh', 'absent', ok=False)
                self.assertEqual(bad.returncode, 1)
                self.assertIs(self.record(bad, 'sched.task.not_found')['state_committed'], False)
                task = self.new(f, review=False)
                good = self.run_helper(f, 'executor', 'task-done.sh', task, 'done')
                self.assertEqual(self.records(good), [])
                self.assertEqual(self.data(f, task)['status'], 'done')

    def test_success_controls(self):
        for provider in FIXTURE.PROVIDERS:
            for op in ['done', 'block']:
                with self.subTest(provider=provider, operation=op):
                    f = self.fixture(provider, 'control-'+op)
                    task = self.new(f); draft = self.draft(f)
                    r = self.run_helper(f, 'reviewer', 'task-'+op+'.sh', task, '--note-file', str(draft))
                    self.assertEqual(self.records(r), [])
                    self.assertEqual(self.event(f, task)['notification']['state'], 'delivered')

    def test_transition_publication_before_after_and_control(self):
        for provider in FIXTURE.PROVIDERS:
            for helper, status in [('task-done.sh', 'done'), ('task-block.sh', 'blocked'), ('task-review.sh', 'review')]:
                for fault in ['before', 'after', 'none']:
                    with self.subTest(provider=provider, helper=helper, fault=fault):
                        f = self.fixture(provider, helper+fault)
                        task = self.new(f, review=False)
                        # Codex review normalizes metadata before the transition.
                        nth = 2 if provider == 'codex' and helper == 'task-review.sh' else 1
                        if fault != 'none': self.mv_failure(f, nth, fault == 'after')
                        r = self.run_helper(f, 'executor', helper, task, 'note', ok=False)
                        if fault == 'none':
                            self.assertEqual(r.returncode, 0, r.stderr)
                            self.assertEqual(self.records(r), [])
                        else:
                            self.assertEqual(r.returncode, 1, r.stderr)
                            row = self.record(r, 'sched.ledger.write_failed')
                            self.assertIs(row['state_committed'], None if fault == 'after' else False)
                            if fault == 'after':
                                self.assertEqual((f['log']/'killed.log').read_text(), 'published\n')
                                self.assertIn('unconfirmed', r.stderr)
                        self.assertEqual(self.data(f, task)['status'], 'assigned' if fault == 'before' else status)
                        locks = Path(f['env']['SESSION_SCHEDULER_HOME'])/'locks'
                        self.assertEqual(list(locks.glob('*.lock')), [])

    def test_verdict_outcome_publication_and_transport_controls(self):
        for provider in FIXTURE.PROVIDERS:
            for fault in ['before', 'after', 'failed-transport', 'none']:
                with self.subTest(provider=provider, fault=fault):
                    f = self.fixture(provider, 'outcome-'+fault)
                    task = self.new(f); draft = self.draft(f)
                    if fault in ['before', 'after']: self.mv_failure(f, 2, fault == 'after')
                    env = {'PROBE_DISPATCH': 'fail', 'PROBE_SEND_RC': '1'} if fault == 'failed-transport' else None
                    r = self.run_helper(f, 'reviewer', 'task-block.sh', task, '--note-file', str(draft), extra=env)
                    self.assertEqual(self.data(f, task)['status'], 'blocked')
                    state = self.event(f, task)['notification']['state']
                    if fault == 'none':
                        self.assertEqual(self.records(r), []); self.assertEqual(state, 'delivered')
                    elif fault == 'failed-transport':
                        row = self.record(r, 'sched.notify.failed')
                        self.assertEqual(row['notification'], {'for':'verdict_event','observed':'failed','persisted':'failed'})
                    else:
                        row = self.record(r, 'sched.notify.record_failed')
                        self.assertIs(row['state_committed'], True)
                        self.assertEqual(row['notification']['persisted'], 'unknown' if fault == 'after' else 'pending')
                        self.assertEqual(state, 'delivered' if fault == 'after' else 'pending')

    def test_packet_failure_retry_and_control(self):
        for provider in FIXTURE.PROVIDERS:
            with self.subTest(provider=provider):
                f = self.fixture(provider, 'packet'); task = self.new(f, review=False)
                packet = Path(f['env']['SESSION_SCHEDULER_HOME'])/'prompts'/(task+'-review.md')
                packet.mkdir()
                first = self.run_helper(f, 'executor', 'task-review.sh', task, 'ready')
                self.assertIs(self.record(first, 'sched.review.packet_write_failed')['state_committed'], True)
                self.assertNotIn('reviewer\n', (f['log']/'dispatch.log').read_text())
                retry = self.run_helper(f, 'executor', 'task-review.sh', task, 'retry')
                self.assertIs(self.record(retry, 'sched.review.packet_write_failed')['state_committed'], False)
                packet.rmdir(); self.reset_log(f)
                control = self.run_helper(f, 'executor', 'task-review.sh', task, 'retry')
                self.assertEqual(self.records(control), [])
                self.assertEqual((f['log']/'dispatch.log').read_text(), 'reviewer\n')

    def test_bookkeeping_route_and_observation(self):
        for provider in FIXTURE.PROVIDERS:
            for queued in [False, True]:
                with self.subTest(provider=provider, queued=queued):
                    f = self.fixture(provider, 'ack-record-'+str(queued))
                    task = self.new(f, review=False)
                    self.mv_failure(f, 2)
                    r = self.run_helper(f, 'executor', 'task-block.sh', task, 'blocked',
                                        extra={'PROBE_DISPATCH': 'queued' if queued else 'ok'})
                    row = self.record(r, 'sched.bookkeeping.last_ack_failed')
                    self.assertIs(row['state_committed'], True)
                    self.assertEqual(row['notification'], {'for': 'assigner_ack',
                                     'observed': 'queued' if queued else 'delivered', 'persisted': 'unknown'})
                    self.assertEqual((f['log']/'dispatch.log').read_text(), 'master\n')
            with self.subTest(provider=provider, route='reviewer'):
                f = self.fixture(provider, 'review-record'); task = self.new(f, review=False)
                self.mv_failure(f, 3)
                r = self.run_helper(f, 'executor', 'task-review.sh', task, 'ready', ok=False)
                row = self.record(r, 'sched.review.record_failed')
                self.assertIs(row['state_committed'], True)
                self.assertEqual(row['notification'], {'for':'reviewer_request','observed':'delivered','persisted':'unknown'})
                self.assertIn('reviewer\n', (f['log']/'dispatch.log').read_text())


if __name__ == '__main__':
    # Avoid silently re-running inherited tests; the separate verdict suite is a gate.
    suite = unittest.TestSuite(Diagnostics(name) for name in Diagnostics.__dict__ if name.startswith('test_'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
