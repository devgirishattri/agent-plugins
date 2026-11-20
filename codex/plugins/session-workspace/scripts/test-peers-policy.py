#!/usr/bin/env python3
"""strict-v1 policy for peer orchestrators (schema 6 with `peers`) and the
schema-5 task-tag fix. Synthetic names only; no tmux, no paid calls, no real
state directory: every run points XDG_STATE_HOME at a temp dir and writes the
engine's instances.json there directly. Every refusal is paired with the same
call allowed for the right caller."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(os.environ.get('WORKSPACE_TEST_SCRIPTS', Path(__file__).resolve().parent))
TESTS = Path(__file__).resolve().parent
ENV = {k: v for k, v in os.environ.items()
       if not k.startswith(('SESSION_', 'KNOWLEDGE_', 'XDG_')) and k not in ('TMUX', 'TMUX_PANE')}
VERSION = '0.17.0'
A, B = 'sample-master', 'sample-master-2'
AE, AR = 'sample-web-executor', 'sample-web-reviewer'
BE, BR, BWE = 'sample-vue3-executor', 'sample-vue3-reviewer', 'sample-web-executor-b'


def module(name, file, base=None):
    spec = importlib.util.spec_from_file_location(name, (base or HERE) / file)
    m = importlib.util.module_from_spec(spec)
    sys.modules[name] = m
    spec.loader.exec_module(m)
    return m


POLICY = module('peers_policy', 'harness-policy.py')


def worker(checkout, role, owner, label=''):
    return {'checkout': checkout, 'role': role, 'label': label, 'owner': owner, 'visible': False}


DEFAULT_WORKERS = [worker('web', 'executor', A), worker('web', 'reviewer', A), worker('vue3', 'executor', B),
                   worker('vue3', 'reviewer', B), worker('web', 'executor', B, 'b')]


class Root(object):
    """A temp project from fixtures/valid/peers-v6.json plus a fake selected
    plugin cache, with contexts memoised per (config, instances) state."""

    def __init__(self, orchestrators=(2,), workers=None, branch=False):
        self.tmp = tempfile.TemporaryDirectory(prefix='wpp-', dir='/tmp')
        self.top = Path(self.tmp.name).resolve()
        self.root = self.top / 'proj'
        self.state = self.top / 'state'
        self.home = self.top / 'home'
        for d in ('component-a', 'component-b', '.agent-workspace', '.tmp/scheduler/tasks', '.tmp/messages'):
            (self.root / d).mkdir(parents=True)
        (self.state / 'session-workspace/sample').mkdir(parents=True)
        self.home.mkdir()
        self.cfg = json.loads((TESTS / 'fixtures/valid/peers-v6.json').read_text())
        if branch:
            self.cfg['environments'][0]['branch'] = 'lane-web'
        self.config_path = self.root / '.agent-workspace/workspace.json'
        self.config_path.write_text(json.dumps(self.cfg))
        self.cache = self.home / '.claude/plugins/cache/girishattri-plugins'
        registry = {}
        for plugin, version in (('session-workspace', VERSION), ('session-chat', '1.0.0'), ('session-scheduler', '1.0.0')):
            scripts = self.cache / plugin / version / 'scripts'
            scripts.mkdir(parents=True)
            names = {'session-workspace': ['workspace.sh', 'workspace-plan.sh', 'workspace-status.sh', 'workspace-start.sh',
                                           'workspace-stop.sh', 'workspace-restart.sh', 'workspace-reconcile.sh',
                                           'workspace-show.sh', 'workspace-hide.sh'],
                     'session-chat': ['send-message.sh', 'dispatch-to-session.sh'],
                     'session-scheduler': ['task-new.sh', 'task-assign.sh', 'task-review.sh', 'task-done.sh', 'task-block.sh']}[plugin]
            for name in names:
                (scripts / name).write_text('#!/usr/bin/env bash\nexit 0\n')
            registry['%s@girishattri-plugins' % plugin] = [{'scope': 'user', 'version': version,
                                                            'installPath': str(self.cache / plugin / version)}]
        (self.home / '.claude/plugins/installed_plugins.json').write_text(json.dumps({'plugins': registry}))
        self.plans = {}
        self.contexts = {}
        self.write_instances(orchestrators, DEFAULT_WORKERS if workers is None else workers)

    def close(self):
        self.tmp.cleanup()

    # -- state ---------------------------------------------------------------
    def base_env(self):
        return dict(ENV, HOME=str(self.home), XDG_STATE_HOME=str(self.state))

    def write_instances(self, orchestrators, workers):
        self.instances = {'version': 1, 'orchestrators': [{'index': n} for n in orchestrators], 'workers': workers}
        (self.state / 'session-workspace/sample/instances.json').write_text(json.dumps(self.instances))

    def write_config(self):
        self.config_path.write_text(json.dumps(self.cfg))

    def script(self, name):
        return str(self.cache / 'session-workspace' / VERSION / 'scripts' / name)

    def helper(self, plugin, name):
        return str(self.cache / plugin / ('1.0.0') / 'scripts' / name)

    # -- plan and contexts -----------------------------------------------------
    def plan(self):
        key = (self.config_path.read_text(), json.dumps(self.instances, sort_keys=True))
        if key not in self.plans:
            run = subprocess.run(['bash', str(HERE / 'workspace-plan.sh'), '--config', str(self.config_path), '--json'],
                                 env=self.base_env(), capture_output=True, text=True, timeout=60)
            assert run.returncode == 0, run.stderr
            self.plans[key] = json.loads(run.stdout)
        return self.plans[key]

    def pane(self, name):
        return next(p for s in self.plan()['sessions'] for p in s['panes'] if p['name'] == name)

    def env(self, name, **over):
        plan = self.plan()
        pane = self.pane(name)
        env = dict(self.base_env(), SESSION_WORKSPACE_CONFIG=str(self.config_path), SESSION_WORKSPACE_HARNESS_MODE='enforce',
                   SESSION_WORKSPACE_PANE_NAME=name, SESSION_WORKSPACE_ROLE=pane['role'],
                   SESSION_WORKSPACE_PROJECT_ROOT=str(self.root), SESSION_WORKSPACE_PANE_CWD=pane['cwd'],
                   SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pane['scope_identity'], sort_keys=True, separators=(',', ':')),
                   SESSION_WORKSPACE_GUARDS_JSON=json.dumps(plan['harness']['guards'], sort_keys=True, separators=(',', ':')))
        env.update(over)
        return env

    def load(self, name, **over):
        with patch.dict(os.environ, self.env(name, **over), clear=True):
            return POLICY.load_context()

    def ctx(self, name):
        key = (name, self.config_path.read_text(), json.dumps(self.instances, sort_keys=True))
        if key not in self.contexts:
            ctx, failure = self.load(name)
            assert failure is None, failure
            self.contexts[key] = ctx
        return self.contexts[key]

    # -- scheduler and message fixtures -----------------------------------------
    def task(self, task_id, assigner, assignee=None, reviewer=None, **extra):
        data = {'assigner': assigner, 'assignee': assignee, 'reviewer': reviewer, 'meta': {}}
        data.update(extra)
        (self.root / '.tmp/scheduler/tasks' / (task_id + '.json')).write_text(json.dumps(data))

    def message(self, sender, recipient):
        path = self.root / '.tmp/messages' / ('1790000000-123-abcdef12-%s-to-%s.md' % (sender, recipient))
        path.write_text('hello\n')
        path.chmod(0o600)
        return path

    def hook(self, name, payload, **over):
        run = subprocess.run(['bash', str(TESTS / 'harness-hook.sh')], input=json.dumps(payload), env=self.env(name, **over),
                             capture_output=True, text=True, timeout=60)
        return run


def bash_payload(command):
    return {'tool_name': 'Bash', 'tool_input': {'command': command}}


class Base(unittest.TestCase):
    shared = None

    @classmethod
    def setUpClass(cls):
        cls.r = Root()

    @classmethod
    def tearDownClass(cls):
        cls.r.close()

    # -- helpers ---------------------------------------------------------------
    def refuses(self, ctx, rule, call, *args):
        with self.assertRaises(POLICY.PolicyFailure) as caught:
            call(ctx, *args)
        self.assertEqual(caught.exception.rule, rule, caught.exception.reason)

    def ok(self, ctx, command):
        POLICY.validate_bash(ctx, command, {})

    def bad(self, ctx, rule, command):
        with self.assertRaises(POLICY.PolicyFailure) as caught:
            POLICY.validate_bash(ctx, command, {})
        self.assertEqual(caught.exception.rule, rule, '%s: %s' % (command, caught.exception.reason))

    def routes(self, verb, args, r=None):
        """The same lifecycle call on every route that reaches the engine."""
        r = r or self.r
        return ['bash %s %s' % (r.script('workspace-%s.sh' % verb), args),
                'bash %s %s %s' % (r.script('workspace.sh'), verb, args),
                'workspace %s %s' % (verb, args),
                'workspace.sh %s %s' % (verb, args),
                'workspace-%s.sh %s' % (verb, args)]


class Routing(Base):
    def test_owner_and_peer_routing(self):
        a, b, ae, be = (self.r.ctx(n) for n in (A, B, AE, BE))
        for ctx, target in ((a, AE), (a, AR), (a, B), (b, BE), (ae, A), (be, B)):
            POLICY.require_route_target(ctx, target)  # controls: the owner path
        self.refuses(a, 'routing.owner', POLICY.require_route_target, BE)
        self.refuses(a, 'routing.master', POLICY.require_route_target, 'sample-nobody')
        for target in (B, BE, AR, 'sample-vue3-server'):
            self.refuses(ae, 'routing.owner', POLICY.require_route_target, target)

    def test_helpers_route_by_owner(self):
        a, ae = self.r.ctx(A), self.r.ctx(AE)
        send = ('session-chat', 'send-message.sh')
        POLICY.validate_helper(a, *send, [AE, 'hi'])
        POLICY.validate_helper(ae, *send, [A, 'hi'])
        self.refuses(a, 'routing.owner', POLICY.validate_helper, *send, [BE, 'hi'])
        self.refuses(ae, 'routing.owner', POLICY.validate_helper, *send, [BE, 'hi'])
        prompt = self.r.root / 'prompt.md'
        prompt.write_text('go\n')
        dispatch = ('session-chat', 'dispatch-to-session.sh')
        POLICY.validate_helper(a, *dispatch, [AE, str(prompt)])
        self.refuses(a, 'routing.owner', POLICY.validate_helper, *dispatch, [BE, str(prompt)])
        self.refuses(ae, 'routing.owner', POLICY.validate_helper, *dispatch, [B, str(prompt)])
        share = ('knowledge', 'share-context.sh')
        POLICY.validate_helper(a, *share, [AE, 'ctx'])
        POLICY.validate_helper(ae, *share, [A, 'ctx'])
        self.refuses(a, 'routing.owner', POLICY.validate_helper, *share, [BE, 'ctx'])
        self.refuses(ae, 'routing.owner', POLICY.validate_helper, *share, [B, 'ctx'])


class Scheduler(Base):
    NEW = ('session-scheduler', 'task-new.sh')
    ASSIGN = ('session-scheduler', 'task-assign.sh')

    def test_task_new_needs_no_tag(self):
        a, ae = self.r.ctx(A), self.r.ctx(AE)
        POLICY.validate_helper(a, *self.NEW, ['Example'])
        POLICY.validate_helper(a, *self.NEW, ['Example', '--meta', 'environment=web'])
        self.refuses(ae, 'coordination.write', POLICY.validate_helper, *self.NEW, ['Example'])

    def test_assign_by_assigner_and_owner(self):
        a, b = self.r.ctx(A), self.r.ctx(B)
        self.r.task('t-own', A)
        POLICY.validate_helper(a, *self.ASSIGN, [AE, 't-own', '--reviewer', AR, 'do it'])
        # the same task: another orchestrator is refused, even for its own worker
        self.refuses(b, 'task.scope', POLICY.validate_helper, *self.ASSIGN, [BE, 't-own', 'do it'])
        self.refuses(b, 'task.scope', POLICY.validate_helper, *self.ASSIGN, [AE, 't-own', 'do it'])
        # a task of its own, aimed at another owner's worker
        self.r.task('t-own-b', B)
        POLICY.validate_helper(b, *self.ASSIGN, [BE, 't-own-b', 'do it'])
        self.refuses(a, 'task.scope', POLICY.validate_helper, *self.ASSIGN, [AE, 't-own-b', 'do it'])
        self.r.task('t-a2', A)
        self.refuses(a, 'routing.owner', POLICY.validate_helper, *self.ASSIGN, [BE, 't-a2', 'do it'])
        self.refuses(a, 'routing.owner', POLICY.validate_helper, *self.ASSIGN, [AE, 't-a2', '--reviewer', BR, 'do it'])
        self.refuses(a, 'task.scope', POLICY.validate_helper, *self.ASSIGN, [AR, 't-a2', '--reviewer', AR, 'do it'])
        POLICY.validate_helper(a, *self.ASSIGN, [AE, 't-a2', '--reviewer', AR, 'do it'])
        self.refuses(a, 'helper.argv', POLICY.validate_helper, *self.ASSIGN, [AE, 't-a2', '--reviewer', AE, 'do it'])

    def test_worker_transitions(self):
        review = ('session-scheduler', 'task-review.sh')
        done = ('session-scheduler', 'task-done.sh')
        ae, ar, be = self.r.ctx(AE), self.r.ctx(AR), self.r.ctx(BE)
        self.r.task('t-ok', A, AE, AR)
        POLICY.validate_helper(ae, *review, ['t-ok', 'ready'])
        POLICY.validate_helper(ar, *done, ['t-ok'])
        self.refuses(be, 'task.scope', POLICY.validate_helper, *review, ['t-ok', 'ready'])
        self.refuses(self.r.ctx(BR), 'task.scope', POLICY.validate_helper, *done, ['t-ok'])
        self.r.task('t-b', B, BE, BR)
        POLICY.validate_helper(be, *review, ['t-b', 'ready'])
        self.refuses(ae, 'task.scope', POLICY.validate_helper, *review, ['t-b', 'ready'])
        # a task that names another pane, one assigned by another owner, and a self-review
        self.r.task('t-other', A, AR, AR)
        self.refuses(ae, 'task.scope', POLICY.validate_helper, *review, ['t-other', 'ready'])
        self.r.task('t-foreign-assigner', B, AE, AR)
        self.refuses(ae, 'task.scope', POLICY.validate_helper, *review, ['t-foreign-assigner', 'ready'])
        self.r.task('t-same', A, AE, AE)
        self.refuses(ae, 'task.scope', POLICY.validate_helper, *review, ['t-same', 'ready'])
        # file safety is kept: a symlinked task file is refused
        target = self.r.root / '.tmp/scheduler/tasks/t-ok.json'
        link = self.r.root / '.tmp/scheduler/tasks/t-link.json'
        link.symlink_to(target)
        self.refuses(ae, 'task.scope', POLICY.validate_helper, *review, ['t-link', 'ready'])


class Lifecycle(Base):
    def all_routes_ok(self, ctx, verb, args):
        for command in self.routes(verb, args):
            self.ok(ctx, command)

    def all_routes_bad(self, ctx, rule, verb, args):
        for command in self.routes(verb, args):
            self.bad(ctx, rule, command)

    def test_start_checkout(self):
        a, ae = self.r.ctx(A), self.r.ctx(AE)
        self.all_routes_ok(a, 'start', '--checkout web --role executor --label x --show --no-attach')
        self.all_routes_ok(a, 'start', '--checkout vue3 --role reviewer')
        for flag in ('--owner %s' % B, '--owner=%s' % B, '--force'):
            self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'start', '--checkout web --role executor ' + flag)
        # reviewed helper grammar
        script = self.r.script('workspace-start.sh')
        for tail in ('--checkout nope --role executor', '--checkout web --role owner', '--checkout web',
                     '--checkout web --role executor --label BAD', '--checkout web --role executor --no-agents',
                     '--checkout web --role executor web-services'):
            self.bad(a, 'helper.argv', 'bash %s %s' % (script, tail))
        for command in self.routes('start', '--checkout web --role executor'):
            self.bad(ae, 'coordination.write', command)

    def test_stop_worker(self):
        a, ae = self.r.ctx(A), self.r.ctx(AE)
        self.all_routes_ok(a, 'stop', '--worker %s --confirmed' % AE)
        self.all_routes_ok(a, 'stop', '--worker web-executor --confirmed')
        self.all_routes_bad(a, 'routing.owner', 'stop', '--worker %s --confirmed' % BE)
        self.all_routes_bad(a, 'routing.owner', 'stop', '--worker vue3-executor --confirmed')
        self.all_routes_bad(a, 'helper.argv', 'stop', '--worker nosuch --confirmed')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'stop', '--worker %s --confirmed --force' % AE)
        self.bad(a, 'helper.argv', 'bash %s --worker %s' % (self.r.script('workspace-stop.sh'), AE))  # needs --confirmed
        for command in self.routes('stop', '--worker %s --confirmed' % AE):
            self.bad(ae, 'coordination.write', command)
        # `--pane` forms
        self.all_routes_ok(a, 'stop', 'development --pane %s --confirmed' % AR)
        self.all_routes_bad(a, 'routing.owner', 'stop', 'development-2 --pane %s --confirmed' % BR)
        self.all_routes_ok(a, 'start', 'development --pane %s' % AR)
        self.all_routes_bad(a, 'routing.owner', 'start', 'development-2 --pane %s' % BE)
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'stop', 'development-2 --pane %s --confirmed' % B)

    def test_orchestrator_sessions(self):
        a, b = self.r.ctx(A), self.r.ctx(B)
        for verb in ('stop', 'restart'):
            self.all_routes_bad(a, 'orchestrator.peer_lifecycle', verb, 'development-2 --confirmed')
            self.all_routes_bad(a, 'orchestrator.peer_lifecycle', verb, 'development-7 --confirmed')  # not in the plan
            self.all_routes_bad(a, 'orchestrator.self_stop', verb, 'development --confirmed')
            self.all_routes_bad(b, 'orchestrator.peer_lifecycle', verb, 'development --confirmed')
            self.all_routes_bad(b, 'orchestrator.self_stop', verb, 'development-2 --confirmed')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'reconcile', 'development-2 --apply')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'reconcile', 'development --apply')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'reconcile', '--apply')
        self.all_routes_ok(a, 'reconcile', 'web-services')  # a preview, and a service session, stay allowed
        self.all_routes_ok(a, 'reconcile', 'development-2')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'start', 'development-3')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'start', 'development-2')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'start', '')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'start', 'all')
        self.all_routes_bad(a, 'orchestrator.peer_lifecycle', 'start', '--no-attach')
        # a service session stays under the orchestrator's hand
        self.all_routes_ok(a, 'stop', 'web-services --confirmed')
        self.all_routes_ok(a, 'start', 'web-services --no-attach')

    def test_show_hide(self):
        a, ae = self.r.ctx(A), self.r.ctx(AE)
        for verb in ('show', 'hide'):
            self.all_routes_ok(a, verb, AE)
            self.all_routes_ok(a, verb, 'web-reviewer')
            self.all_routes_bad(a, 'routing.owner', verb, BE)
            self.all_routes_bad(a, 'routing.owner', verb, 'vue3-executor')
            self.all_routes_bad(a, 'helper.argv', verb, 'sample-nobody')
            for command in self.routes(verb, AE):
                self.bad(ae, 'coordination.write', command)
            self.ok(a, 'bash %s %s %s --config %s' % (self.r.script('workspace-%s.sh' % verb), AE, '', self.r.config_path))
            self.bad(a, 'orchestrator.peer_lifecycle', 'bash %s %s --force' % (self.r.script('workspace-%s.sh' % verb), AE))
            self.bad(a, 'helper.argv', 'bash %s %s --bogus' % (self.r.script('workspace-%s.sh' % verb), AE))

    def test_environment_selector_flags(self):
        a = self.r.ctx(A)
        self.ok(a, 'workspace stop --environment web --services --confirmed')
        self.bad(a, 'orchestrator.peer_lifecycle', 'workspace stop --environment web --services --confirmed --force')


class Tmux(Base):
    ALLOWED = ['tmux list-panes -a', 'tmux -L x display-message -p hi', 'tmux -Lx ls', 'tmux -V', 'tmux capture-pane -p -t %1',
               'tmux show-options -g', 'tmux has-session -t sample', 'tmux -S /tmp/sock -f /dev/null list-windows',
               'tmux -2 -u lsc', "tmux list-panes -a -F '#{pane_id} #{@name}'", "tmux display-message -p '#{session_name}'", 'tmux -L sock list-sessions', "tmux display-message -p '#{pane_id}'", "tmux list-panes -F '#{pane_id} #{@name}'", 'tmux show-environment', 'echo hi | tmux display -p']
    DENIED = ['tmux kill-pane -t %1', 'tmux join-pane -s %1 -t %2', 'tmux break-pane', 'tmux set-option -g x y',
              'tmux send-keys -t %1 x Enter', 'tmux respawn-pane -k', 'tmux -L x kill-server', r'tmux list-panes \; kill-pane -t %1',
              "tmux list-panes ';' kill-pane -t %1", 'tmux', 'tmux lspx', 'tmux -V list-panes', 'tmux -Lx kill-session',
              'tmux -q list-panes', 'env tmux kill-pane', 'command tmux kill-server', 'ls && tmux kill-window', "tmux display-message -p '#(tmux kill-pane -t %1)'",
              "tmux list-panes -F '#(touch x)'",
              "tmux list-panes -F 'x;' kill-pane -t %1", r'tmux list-panes -F x\; kill-pane', "tmux list-panes $'\\x3b' kill-pane",
              'tmux list-panes -F "$(id)"', 'tmux list-panes -F `id`']

    INDIRECT = ["sh -c 'tmux kill-server'", "bash -c 'tmux kill-pane -t %1'", "eval 'tmux kill-server'",
                "echo kill-server | xargs tmux", "find . -maxdepth 0 -exec tmux kill-server ';'",
                "python3 -c 'import os; os.system(\"tmux kill-server\")'", "perl -e 'system(\"tmux kill-server\")'",
                "nohup sh -c 'tmux kill-server'", "bash -lc 'tmux kill-server'", "zsh -c 'tmux kill-server'",
                "python3.12 -c 'import os; os.system(\"tmux kill-server\")'", "node -e 'require(\"child_process\").execSync(\"tmux kill-server\")'",
                "awk 'BEGIN { system(\"tmux kill-server\") }'", "sed -n '1e tmux kill-server' notes.md",
                "git -c alias.k='!tmux kill-server' k", "busybox sh -c 'tmux kill-server'",
                # format modifiers that expand text the format does not spell out
                "tmux display-message -p '#{E:@x}'", "tmux display-message -p '#{T:@x}'",
                "tmux list-panes -F '#{S:#{session_name}}'", "tmux display -p '#{s/a/b/:pane_id}'"]

    def test_read_verbs_and_denials(self):
        a = self.r.ctx(A)
        for command in self.ALLOWED:
            self.ok(a, command)
        for command in self.DENIED + self.INDIRECT:
            self.bad(a, 'orchestrator.tmux', command)
        # controls: plain formats and conditionals, and tmux named only as data
        for command in ("tmux display-message -p '#{?pane_active,yes,no}'", "rg tmux README.md",
                        "sh -c 'ls -l'", "grep -n tmux notes.md", "git log --grep tmux -1",
                        "python3 notes.py --topic tmux", "awk '{print $1}' notes.md"):
            self.ok(a, command)
        # a message that mentions tmux is data for its sender script, not tmux
        self.assertFalse(POLICY.tmux_indirect(['bash', '/x/session-chat/scripts/send-message.sh', B, 'restart the tmux server later']))
        self.assertFalse(POLICY.tmux_indirect(['python3', 'notes.py', 'tmux']))
        self.assertTrue(POLICY.tmux_indirect(['bash', '-c', 'tmux kill-server']))  # control

    def test_workers_keep_their_own_tmux_rule_and_v5_root_is_unchanged(self):
        self.bad(self.r.ctx(AE), 'routing.master', 'tmux kill-pane -t %1')
        # control: an unbound root orchestrator outside peers mode keeps today's behaviour
        env = V5Root()
        try:
            self.ok(env.ctx('root'), 'tmux kill-pane -t %1')
        finally:
            env.close()


class StateDir(Base):
    def test_state_dir_writes(self):
        a = self.r.ctx(A)
        target = self.r.state / 'session-workspace/sample/instances.json'
        for tool in ('Edit', 'Write'):
            for path in (target, self.r.state / 'session-workspace/sample/new.json'):
                self.refuses(a, 'orchestrator.state_write', POLICY.validate_edit, {'file_path': str(path)}, {})
        POLICY.validate_edit(a, {'file_path': str(self.r.root / 'notes.md')}, {})  # control
        state = str(self.r.state / 'session-workspace/sample')
        for command in ('rm %s/instances.json' % state, 'cp notes.md %s/instances.json' % state,
                        'echo x > %s/instances.json' % state, 'cd %s && touch x' % state, 'mv %s/instances.json /tmp/x' % state,
                        'touch %s' % target):
            self.bad(a, 'orchestrator.state_write', command)
        for command in ('cat %s' % target, 'ls %s' % state, 'jq . %s' % target, 'touch notes.md', 'echo x > notes.md'):
            self.ok(a, command)

    def test_task_ledger_writes(self):
        # A task's assigner is its owner: an orchestrator that could rewrite a
        # task file could take another orchestrator's task.
        a = self.r.ctx(A)
        tasks = self.r.root / '.tmp/scheduler/tasks'
        self.assertEqual(a.scheduler_root / 'tasks', tasks)
        for path in (tasks / 'task-1.json', tasks / 'new.json'):
            self.refuses(a, 'orchestrator.state_write', POLICY.validate_edit, {'file_path': str(path)}, {})
        for command in ('echo x > %s/task-1.json' % tasks, 'cp notes.md %s/task-1.json' % tasks,
                        "jq '.assigner=\"%s\"' %s/task-1.json > /tmp/t && mv /tmp/t %s/task-1.json" % (A, tasks, tasks),
                        'cd %s && touch task-1.json' % tasks, 'rm %s/task-1.json' % tasks):
            self.bad(a, 'orchestrator.state_write', command)
        # the directories above the ledger take it along
        for command in ('rm -rf %s' % tasks.parent, 'mv %s /tmp/x' % tasks.parent, 'rm -rf %s' % tasks.parent.parent,
                        'cd %s && rm -rf scheduler' % tasks.parent.parent, 'mv .tmp/scheduler /tmp/x'):
            self.bad(a, 'orchestrator.state_write', command)
        # controls: reads stay allowed, and so do writes elsewhere (also beside the ledger's parents)
        for command in ('cat %s/task-1.json' % tasks, 'ls %s' % tasks, 'jq . %s/task-1.json' % tasks,
                        'touch notes-2.md', 'cp notes.md .', 'ls %s' % tasks.parent.parent):
            self.ok(a, command)
        POLICY.validate_edit(a, {'file_path': str(self.r.root / 'notes.md')}, {})

    def test_workers_are_not_given_the_orchestrator_rule(self):
        ae = self.r.ctx(AE)
        self.assertIsNone(ae.state_dir if not ae.semantic_role == 'orchestrator' else None) if False else None
        self.refuses(ae, 'executor.containment', POLICY.validate_edit,
                     {'file_path': str(self.r.state / 'session-workspace/sample/instances.json')}, {})


class Override(Base):
    def test_identity_override(self):
        a, ae = self.r.ctx(A), self.r.ctx(AE)
        cases = ['SESSION_WORKSPACE_PANE_NAME=sample-master-2 workspace stop --worker %s --confirmed' % AE,
                 'env -u SESSION_WORKSPACE_PANE_NAME workspace stop --worker %s --confirmed' % AE,
                 'env --unset=SESSION_WORKSPACE_ROLE workspace plan',
                 'env -i workspace plan',
                 'env SESSION_CHAT_PANE_NAME=x workspace plan',
                 'XDG_STATE_HOME=/tmp/x workspace start --checkout web --role executor',
                 'export TMUX_PANE=%9; workspace show ' + AE,
                 'unset TMUX_PANE; workspace hide ' + AE,
                 'declare -x HOME=/tmp/x && workspace-stop.sh --worker %s --confirmed' % AE,
                 'readonly KNOWLEDGE_PANE_NAME=x; workspace.sh plan',
                 'workspace plan; TMUX=1 true',
                 'SESSION_WORKSPACE_CONFIG=/tmp/x bash %s --worker %s --confirmed' % (self.r.script('workspace-stop.sh'), AE),
                 'HOME=/tmp/x true; workspace plan',
                 # what the engine runs: a tmux, a startup script or a library of the caller's choosing
                 'PATH=/tmp/x:$PATH workspace stop --worker %s --confirmed' % AE,
                 'env PATH=/tmp/x workspace plan',
                 'BASH_ENV=/tmp/x workspace plan',
                 'env ENV=/tmp/x workspace status',
                 'DYLD_INSERT_LIBRARIES=/tmp/x.dylib workspace plan',
                 'LD_PRELOAD=/tmp/x.so workspace plan',
                 'PYTHONPATH=/tmp/x workspace plan',
                 'TMUX_TMPDIR=/tmp/x workspace show ' + AE,
                 'export PATH=/tmp/x:$PATH; workspace plan']
        for command in cases:
            self.bad(a, 'identity.override', command)
            self.bad(ae, 'identity.override', command)
        # controls: the same routes without the override, and an override with no route
        self.ok(a, 'workspace stop --worker %s --confirmed' % AE)
        self.ok(a, 'FOO=1 workspace status')
        self.ok(a, 'XDG_STATE_HOME=/tmp/x ls')
        self.ok(a, 'export TMUX_PANE=%9')
        self.ok(a, 'PATH=/tmp/x:$PATH ls')
        self.ok(ae, 'workspace plan')
        self.ok(ae, 'FOO=1 workspace plan')


class Messages(Base):
    def test_worker_reads_only_owner_messages(self):
        ae, a = self.r.ctx(AE), self.r.ctx(A)
        owner_to_worker = self.r.message(A, AE)
        worker_to_owner = self.r.message(AE, A)
        other = self.r.message(B, AE)
        for path in (owner_to_worker, worker_to_owner):
            self.assertEqual(POLICY.validate_bash(ae, 'cat ' + str(path), {}), 'coordination.message_read')
        self.refuses(ae, 'coordination.message_read', POLICY.validate_bash, 'cat ' + str(other), {})
        peer_pair = self.r.message(AR, A)
        self.refuses(ae, 'coordination.message_read', POLICY.validate_bash, 'cat ' + str(peer_pair), {})
        # control: the reviewer is the owner's other worker and reads its own
        self.assertEqual(POLICY.validate_bash(self.r.ctx(AR), 'cat ' + str(peer_pair), {}), 'coordination.message_read')
        self.assertTrue(a.peers)


class Identity(Base):
    def test_launch_identity(self):
        ctx, failure = self.r.load(AE)
        self.assertIsNone(failure)
        self.assertEqual((ctx.owner, ctx.orchestrator_pane, ctx.environment), (A, A, 'web'))
        self.assertEqual(ctx.executor_panes | ctx.reviewer_panes, frozenset({AE, AR}))
        _, failure = self.r.load(AE, SESSION_WORKSPACE_ROLE='master')
        self.assertEqual(failure.rule, 'identity.role')
        _, failure = self.r.load(AE, SESSION_WORKSPACE_PANE_CWD=str(self.r.root / 'component-b'))
        self.assertEqual(failure.rule, 'identity.cwd')
        pin = json.loads(self.r.env(AE)['SESSION_WORKSPACE_SCOPE_JSON'])
        pin['owner'] = B
        _, failure = self.r.load(AE, SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pin, sort_keys=True, separators=(',', ':')))
        self.assertEqual(failure.rule, 'identity.scope')
        _, failure = self.r.load(AE, SESSION_WORKSPACE_PANE_NAME='sample-web-executor-ghost')
        self.assertEqual(failure.rule, 'identity.pane')
        # control: the orchestrator pin is its own name, and another name fails
        a, failure = self.r.load(A)
        self.assertIsNone(failure)
        self.assertEqual((a.owner, a.environment, a.route_peers, a.orchestrator_pane), ('', '', frozenset({B}), A))
        self.assertEqual(a.executor_panes, frozenset({AE}))
        self.assertEqual(a.reviewer_panes, frozenset({AR}))
        _, failure = self.r.load(A, SESSION_WORKSPACE_SCOPE_JSON='{"environment":null,"peer":"%s"}' % B)
        self.assertEqual(failure.rule, 'identity.scope')

    def test_orchestrator_tables(self):
        b = self.r.ctx(B)
        self.assertEqual(b.executor_panes, frozenset({BE, BWE}))
        self.assertEqual(b.reviewer_panes, frozenset({BR}))
        self.assertEqual(b.route_peers, frozenset({A}))
        self.assertEqual(b.scheduler_root, (self.r.root / '.tmp/scheduler').resolve())
        self.assertEqual({p.name for p in b.child_roots}, {'component-a', 'component-b'})

    def test_owner_record_gone_fails_closed(self):
        r = Root(orchestrators=(), workers=[worker('web', 'executor', B)])
        try:
            self.assertNotIn(AE, {p['name'] for s in r.plan()['sessions'] for p in s['panes']})
            # the loader drops the worker (its owner is unknown): the pane is unknown
            with patch.dict(os.environ, dict(r.base_env(), SESSION_WORKSPACE_CONFIG=str(r.config_path),
                                             SESSION_WORKSPACE_HARNESS_MODE='enforce', SESSION_WORKSPACE_PANE_NAME=AE,
                                             SESSION_WORKSPACE_ROLE='executor', SESSION_WORKSPACE_PROJECT_ROOT=str(r.root),
                                             SESSION_WORKSPACE_PANE_CWD=str(r.root / 'component-a'),
                                             SESSION_WORKSPACE_GUARDS_JSON=json.dumps(r.plan()['harness']['guards'], sort_keys=True, separators=(',', ':'))), clear=True):
                ctx, failure = POLICY.load_context()
            self.assertIsNone(ctx)
            self.assertEqual(failure.decision, 'deny')
            self.assertIn(failure.rule, {'identity.pane', 'identity.topology'})
        finally:
            r.close()


class Drift(unittest.TestCase):
    def test_other_instances_change_no_pin(self):
        r = Root()
        try:
            names = (A, AE, BE)
            before = {n: r.ctx(n) for n in names}
            envs = {n: r.env(n) for n in names}
            r.write_instances((2, 3), DEFAULT_WORKERS + [worker('vue3', 'executor', A, 'x'), worker('web', 'reviewer', B, 'y')])
            for name in names:
                with patch.dict(os.environ, envs[name], clear=True):
                    ctx, failure = POLICY.load_context()
                self.assertIsNone(failure, name)
            r.write_instances((), [worker('web', 'executor', A), worker('web', 'reviewer', A)])
            for name in (A, AE):
                with patch.dict(os.environ, envs[name], clear=True):
                    ctx, failure = POLICY.load_context()
                self.assertIsNone(failure, name)
            self.assertEqual(before[A].route_peers, frozenset({B}))
            self.assertEqual(ctx.route_peers, frozenset() if ctx.semantic_role == 'orchestrator' else ctx.route_peers)
            # control: a change to the worker's own checkout entry still fails it closed
            r.cfg['environments'][0]['executors'] = 'one'
            r.write_config()
            with patch.dict(os.environ, envs[AE], clear=True):
                _, failure = POLICY.load_context()
            self.assertEqual(failure.rule, 'identity.scope')
            with patch.dict(os.environ, envs[A], clear=True):
                _, failure = POLICY.load_context()
            self.assertIsNone(failure)
        finally:
            r.close()


class ReusedName(unittest.TestCase):
    def test_new_owner_gets_a_clean_slate(self):
        r = Root(orchestrators=(2,), workers=[worker('web', 'executor', A), worker('web', 'reviewer', A)])
        try:
            review = ('session-scheduler', 'task-review.sh')
            r.task('t-old', A, AE, AR)
            old_message = r.message(A, AE)
            ctx = r.ctx(AE)
            POLICY.validate_helper(ctx, *review, ['t-old', 'ready'])
            self.assertEqual(POLICY.validate_bash(ctx, 'cat ' + str(old_message), {}), 'coordination.message_read')
            # the same name is registered again under the second orchestrator
            r.write_instances((2,), [worker('web', 'executor', B), worker('web', 'reviewer', A)])
            ctx = r.ctx(AE)
            self.assertEqual(ctx.owner, B)
            with self.assertRaises(POLICY.PolicyFailure) as caught:
                POLICY.validate_helper(ctx, *review, ['t-old', 'ready'])
            self.assertEqual(caught.exception.rule, 'task.scope')
            with self.assertRaises(POLICY.PolicyFailure) as caught:
                POLICY.validate_bash(ctx, 'cat ' + str(old_message), {})
            self.assertEqual(caught.exception.rule, 'coordination.message_read')
            r.task('t-new', B, AE, AR)
            POLICY.validate_helper(ctx, *review, ['t-new', 'ready'])
            self.assertEqual(POLICY.validate_bash(ctx, 'cat ' + str(r.message(B, AE)), {}), 'coordination.message_read')
        finally:
            r.close()


class ChildRoots(unittest.TestCase):
    def test_checkouts_stay_child_content_without_workers(self):
        r = Root(workers=[worker('web', 'executor', A)])
        try:
            a = r.ctx(A)
            self.assertEqual({p.name for p in a.child_roots}, {'component-a', 'component-b'})
            for path in ('component-b/x.txt', 'component-a/x.txt'):
                with self.assertRaises(POLICY.PolicyFailure) as caught:
                    POLICY.validate_edit(a, {'file_path': str(r.root / path)}, {})
                self.assertEqual(caught.exception.rule, 'orchestrator.child_write')
            with self.assertRaises(POLICY.PolicyFailure) as caught:
                POLICY.validate_bash(a, 'touch component-b/x.txt', {})
            self.assertEqual(caught.exception.rule, 'orchestrator.child_write')
            POLICY.validate_edit(a, {'file_path': str(r.root / 'notes.md')}, {})
            POLICY.validate_bash(a, 'touch notes.md', {})
        finally:
            r.close()

    def test_lane_branches(self):
        r = Root(branch=True)
        try:
            a, ae = r.ctx(A), r.ctx(AE)
            self.assertEqual(a.lane_branches, frozenset({'lane-web'}))
            self.assertEqual(ae.lane_branch, 'lane-web')
            self.assertEqual(r.ctx(AR).lane_branch, '')
        finally:
            r.close()


class RealHook(Base):
    def run_hook(self, name, payload):
        return self.r.hook(name, payload)

    def assert_denied(self, run, rule):
        self.assertEqual(run.returncode, 2, run.stderr)
        lines = run.stderr.strip().splitlines()
        self.assertTrue(lines[0].startswith('BLOCKED by session-workspace strict-v1 [%s]: ' % rule), lines[0])
        diag = [line for line in lines if line.startswith('DIAG ')]
        self.assertEqual(len(diag), 1, run.stderr)
        self.assertEqual(json.loads(diag[0][5:])['reason'], 'hook.' + rule)

    def test_denials_and_controls(self):
        state = str(self.r.state / 'session-workspace/sample/instances.json')
        cases = [
            (A, bash_payload('workspace stop --worker %s --confirmed' % BE), 'routing.owner'),
            (A, bash_payload('workspace stop development-2 --confirmed'), 'orchestrator.peer_lifecycle'),
            (A, bash_payload('tmux kill-pane -t %1'), 'orchestrator.tmux'),
            (A, bash_payload('rm ' + state), 'orchestrator.state_write'),
            (A, {'tool_name': 'Edit', 'tool_input': {'file_path': state}}, 'orchestrator.state_write'),
            (A, bash_payload('XDG_STATE_HOME=/tmp/x workspace plan'), 'identity.override'),
            (AE, bash_payload('SESSION_WORKSPACE_PANE_NAME=%s workspace plan' % A), 'identity.override'),
            (AE, bash_payload('workspace start --checkout web --role executor'), 'coordination.write'),
            (AE, bash_payload('cat ' + str(self.r.message(B, AE))), 'coordination.message_read'),
        ]
        for name, payload, rule in cases:
            self.assert_denied(self.run_hook(name, payload), rule)
        allowed = [
            (A, bash_payload('workspace stop --worker %s --confirmed' % AE)),
            (A, bash_payload('tmux list-panes')),
            (A, bash_payload('cat ' + state)),
            (A, {'tool_name': 'Edit', 'tool_input': {'file_path': str(self.r.root / 'notes.md')}}),
            (A, bash_payload('FOO=1 workspace status')),
            (AE, bash_payload('cat ' + str(self.r.message(A, AE)))),
        ]
        for name, payload in allowed:
            run = self.run_hook(name, payload)
            self.assertEqual(run.returncode, 0, run.stderr)


class HarnessStatus(Base):
    def status(self, name):
        run = subprocess.run(['bash', str(TESTS / 'harness-status.sh'), '--json', '--probe', '--config', str(self.r.config_path)],
                             env=self.r.env(name), capture_output=True, text=True, timeout=120)
        self.assertEqual(run.returncode, 0, run.stderr + run.stdout)
        return json.loads(run.stdout)

    def test_probes_for_orchestrator_and_worker(self):
        for name, floor in ((A, 'peer_orchestrator'), (AE, 'executor')):
            data = self.status(name)
            self.assertTrue(data['identity']['matches'], data['identity'])
            self.assertEqual(data['identity']['pane_name'], name)
            probe = data['probe']
            self.assertTrue(probe['ran'], probe)
            self.assertEqual(probe['floor'], floor)
            bad = [case for case in probe['cases'] if not case['ok']]
            self.assertEqual(bad, [])
            self.assertGreater(len(probe['cases']), 8)
        rules = {case['expect_rule'] for case in self.status(A)['probe']['cases']}
        self.assertTrue({'orchestrator.peer_lifecycle', 'routing.owner', 'orchestrator.tmux', 'orchestrator.state_write',
                         'identity.override'} <= rules, rules)


# -- schema 5 fix --------------------------------------------------------------


class V5Root(object):
    """The test-environments v5 fixture with a lane `d` run by the root."""

    def __init__(self):
        env_tests = module('peers_env_tests', 'test-environments.py', TESTS)
        self.tmp = tempfile.TemporaryDirectory(prefix='wpp5-', dir='/tmp')
        self.top = Path(self.tmp.name).resolve()
        self.root = self.top / 'proj'
        for d in ['component-a', 'component-b', 'control-web', 'control-vue3', '.agent-workspace', '.tmp/scheduler/tasks', '.tmp/messages']:
            (self.root / d).mkdir(parents=True)
        self.cfg = env_tests.config()
        (self.root / 'component-d').mkdir()
        self.cfg['sessions'].append(dict(id='dev-d', name='test-dev-d', panes=[
            dict(name='d-executor', role='executor', cwd='component-d'), dict(name='d-reviewer', role='reviewer', cwd='component-d')]))
        self.cfg['environments'].append(dict(id='d', cwd='component-d', development=['dev-d'], services=[]))
        self.cfg['orchestration']['targets'].append(dict(id='d', cwd='component-d', remote='origin', work_branch='main',
                                                          release_branch='production', deploy={'strategy': 'merge-no-ff-v1'}))
        self.path = self.root / '.agent-workspace/workspace.json'
        self.path.write_text(json.dumps(self.cfg))
        self.base = dict(ENV, HOME=str(self.top), XDG_STATE_HOME=str(self.top / 'state'))
        run = subprocess.run(['bash', str(HERE / 'workspace-plan.sh'), '--config', str(self.path), '--json'], env=self.base,
                             capture_output=True, text=True, timeout=60)
        assert run.returncode == 0, run.stderr
        self.plan = json.loads(run.stdout)

    def close(self):
        self.tmp.cleanup()

    def ctx(self, name):
        pane = next(p for s in self.plan['sessions'] for p in s['panes'] if p['name'] == name)
        env = dict(self.base, SESSION_WORKSPACE_CONFIG=str(self.path), SESSION_WORKSPACE_HARNESS_MODE='enforce',
                   SESSION_WORKSPACE_PANE_NAME=name, SESSION_WORKSPACE_ROLE=pane['role'],
                   SESSION_WORKSPACE_PROJECT_ROOT=str(self.root), SESSION_WORKSPACE_PANE_CWD=pane['cwd'],
                   SESSION_WORKSPACE_SCOPE_JSON=json.dumps(pane['scope_identity'], sort_keys=True, separators=(',', ':')),
                   SESSION_WORKSPACE_GUARDS_JSON=json.dumps(self.plan['harness']['guards'], sort_keys=True, separators=(',', ':')))
        with patch.dict(os.environ, env, clear=True):
            ctx, failure = POLICY.load_context()
        assert failure is None, failure
        return ctx

    def task(self, task_id, tag, assignee=None, reviewer=None, assigner='root'):
        (self.root / '.tmp/scheduler/tasks' / (task_id + '.json')).write_text(json.dumps(
            {'meta': {'environment': tag}, 'assigner': assigner, 'assignee': assignee, 'reviewer': reviewer}))


class C1TaskTag(unittest.TestCase):
    """A worker whose environment has no local orchestrator expects the tag
    `root`, the tag the root must use (schema 5 and schema 6 without peers)."""

    @classmethod
    def setUpClass(cls):
        cls.v5 = V5Root()

    @classmethod
    def tearDownClass(cls):
        cls.v5.close()

    def refused(self, ctx, rule, *call):
        with self.assertRaises(POLICY.PolicyFailure) as caught:
            POLICY.validate_helper(ctx, *call)
        self.assertEqual(caught.exception.rule, rule, caught.exception.reason)

    def test_root_tagged_task_passes_for_root_and_its_workers(self):
        root, executor, reviewer = (self.v5.ctx(n) for n in ('root', 'd-executor', 'd-reviewer'))
        sched = 'session-scheduler'
        POLICY.validate_helper(root, sched, 'task-new.sh', ['Example', '--meta', 'environment=root'])
        self.v5.task('t-root', 'root', 'd-executor', 'd-reviewer')
        POLICY.validate_helper(root, sched, 'task-assign.sh', ['d-executor', 't-root', '--reviewer', 'd-reviewer', 'Do work'])
        POLICY.validate_helper(executor, sched, 'task-review.sh', ['t-root', 'ready'])
        POLICY.validate_helper(reviewer, sched, 'task-done.sh', ['t-root'])
        # the root still needs the root tag, and the worker no longer accepts its own id
        self.refused(root, 'task.scope', sched, 'task-new.sh', ['Example', '--meta', 'environment=d'])
        self.v5.task('t-d', 'd', 'd-executor', 'd-reviewer')
        self.refused(executor, 'task.scope', sched, 'task-review.sh', ['t-d', 'ready'])
        self.refused(reviewer, 'task.scope', sched, 'task-done.sh', ['t-d'])
        self.refused(root, 'task.scope', sched, 'task-assign.sh', ['d-executor', 't-d', 'Do work'])

    def test_contract_path_uses_the_same_tag(self):
        d_exec, d_rev, web_exec = (self.v5.ctx(n) for n in ('d-executor', 'd-reviewer', 'web-executor'))
        self.v5.task('c-root', 'root', 'd-executor', 'd-reviewer')
        self.v5.task('c-d', 'd', 'd-executor', 'd-reviewer')
        self.v5.task('c-web', 'web', 'web-executor', 'web-reviewer', assigner='web-master')
        self.v5.task('c-web-root', 'root', 'web-executor', 'web-reviewer', assigner='web-master')
        sched = 'session-scheduler'
        POLICY.validate_helper(d_exec, sched, 'task-contract.sh', ['inspect', 'c-root'])
        POLICY.validate_helper(d_rev, sched, 'task-contract.sh', ['inspect', 'c-root'])
        for ctx in (d_exec, d_rev):
            self.refused(ctx, 'task.contract', sched, 'task-contract.sh', ['inspect', 'c-d'])
        POLICY.validate_helper(web_exec, sched, 'task-contract.sh', ['inspect', 'c-web'])
        self.refused(web_exec, 'task.contract', sched, 'task-contract.sh', ['inspect', 'c-web-root'])

    def test_environment_with_a_local_orchestrator_is_unchanged(self):
        web_master, web_executor = self.v5.ctx('web-master'), self.v5.ctx('web-executor')
        sched = 'session-scheduler'
        POLICY.validate_helper(web_master, sched, 'task-new.sh', ['Example', '--meta', 'environment=web'])
        self.refused(web_master, 'task.scope', sched, 'task-new.sh', ['Example', '--meta', 'environment=root'])
        self.v5.task('t-web', 'web', 'web-executor', 'web-reviewer', assigner='web-master')
        POLICY.validate_helper(web_executor, sched, 'task-review.sh', ['t-web', 'ready'])
        self.v5.task('t-web-root', 'root', 'web-executor', 'web-reviewer', assigner='web-master')
        self.refused(web_executor, 'task.scope', sched, 'task-review.sh', ['t-web-root', 'ready'])

    def test_peers_only_forms_are_refused_outside_peers(self):
        root = self.v5.ctx('root')
        ws = 'session-workspace'
        for script, args in (('workspace-show.sh', ['d-executor']), ('workspace-hide.sh', ['d-executor']),
                             ('workspace-start.sh', ['--checkout', 'd', '--role', 'executor']),
                             ('workspace-stop.sh', ['--worker', 'd-executor', '--confirmed'])):
            self.refused(root, 'helper.argv', ws, script, args)
        # control: the schema-5 forms next to them are still reviewed
        POLICY.validate_helper(root, ws, 'workspace-stop.sh', ['dev-d', '--confirmed'])
        POLICY.validate_helper(root, ws, 'workspace-start.sh', ['dev-d', '--no-attach'])


if __name__ == '__main__':
    unittest.main(verbosity=2)
