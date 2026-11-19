#!/usr/bin/env python3
"""Closed v5/v6 environment validation; no network or credential reads.

Schema 6 without `peers` is validated exactly as schema 5. With `peers` the
config is the loader's expanded form (config.sh sw_apply_instances): the
declared orchestrator session, its numbered copies and the worker panes the
engine recorded. Several rules that assume one fixed set of declared panes
then give way to checks of the expanded fleet (validate_peers)."""
import json
import re
import sys
from pathlib import Path


def inside(path, root):
    return path == root or root in path.parents


def pane_runtime(cfg, pane):
    return pane.get('runtime', cfg['roles'][pane['role']]['runtime'])


def git_common_dir(path):
    """(common git dir, is a linked worktree) for the checkout whose root is
    PATH, or (None, False) when PATH holds no readable `.git`."""
    marker = path / '.git'
    try:
        if marker.is_symlink():
            return None, False
        if marker.is_dir():
            return marker.resolve(), False
        if not marker.is_file():
            return None, False
        with marker.open('r', encoding='utf-8') as handle:
            first = handle.readline(4096).strip()
        if not first.startswith('gitdir:') or not first[len('gitdir:'):].strip():
            return None, False
        gitdir = Path(first[len('gitdir:'):].strip())
        gitdir = gitdir if gitdir.is_absolute() else path / gitdir
        commondir = gitdir / 'commondir'
        text = ''
        if commondir.is_file():
            with commondir.open('r', encoding='utf-8') as handle:
                text = handle.readline(4096).strip()
    except (OSError, UnicodeError):
        return None, False
    if not text:
        return gitdir.resolve(), False  # a submodule keeps its own git dir
    common = Path(text)
    return (common if common.is_absolute() else gitdir / common).resolve(), True


def branch_name_valid(name):
    return (isinstance(name, str) and name != 'HEAD' and len(name) <= 200
            and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._/-]*', name) is not None
            and '..' not in name and '//' not in name and not name.endswith(('/', '.', '.lock'))
            and not any(part.startswith('.') or part.endswith('.lock') for part in name.split('/')))


REMOVED = 'was removed in session-workspace 0.12.0; delete it from the config'


def removed_features(cfg):
    """Report removed Jev configuration forms so old configs fail with a migration message."""
    found = []
    if 'integrations' in cfg:
        found.append('integrations (Jev) ' + REMOVED)
    envs = cfg.get('environments')
    if isinstance(envs, list) and any(isinstance(e, dict) and 'jev' in e for e in envs):
        found.append('environments[].jev ' + REMOVED)
    pin = cfg.get('stores', {}).get('pin') if isinstance(cfg.get('stores'), dict) else None
    if isinstance(pin, list) and 'integrations' in pin:
        found.append('"integrations" in stores.pin ' + REMOVED)
    return found


def validate_peers(cfg, root, envs, sessions, roles, require):
    peers = cfg['peers']
    sid = peers['session']
    require(cfg.get('harness', {}).get('enabled', False) is True and bool(envs), 'peers requires an enabled harness and non-empty environments')
    require(sid in sessions, 'peers.session must name a declared session')
    env_cwds = {e['id']: e['cwd'] for e in envs}
    declared = sessions[sid]
    fixed = [p for p in declared['panes'] if 'worker' not in p]
    require(len(fixed) == 1 and fixed[0]['role'] == roles['orchestrator'],
            'peers.session %s must declare exactly one pane, with the orchestrator role' % sid)
    orchestrator = fixed[0]
    require((root / orchestrator.get('cwd', '.')).resolve(strict=True) == root, 'the peers orchestrator pane must run at the workspace root')
    require(not orchestrator.get('optional', False) and 'launch' not in orchestrator, 'the peers orchestrator pane must not be optional and must not set launch')
    layout = declared.get('layout', {})
    require(layout.get('kind', 'standard') == 'standard', 'peers.session must use the standard layout (no split_tree)')
    require(not declared.get('retain_layout', False), 'peers.session must not set retain_layout')
    for s in sessions.values():
        mine = [p for p in s['panes'] if p['role'] == roles['orchestrator']]
        for p in mine:
            require(s.get('instance', {}).get('of') == sid, 'orchestrator pane %s must be the pane of the peers session %s; further orchestrators are started with `workspace start %s-N`' % (p['name'], sid, sid))
        require(len(mine) <= 1, 'session %s holds more than one orchestrator pane' % s['id'])
        for p in s['panes']:
            if p['role'] not in (roles['executor'], roles['reviewer']):
                require('worker' not in p, 'pane %s: only executor and reviewer panes carry worker' % p['name'])
                continue
            worker = p.get('worker')
            require(isinstance(worker, dict) and worker.get('checkout') in env_cwds,
                    'pane %s has the executor or reviewer role but is not an engine-started worker of a configured environment; workers are started with `workspace start --checkout`' % p['name'])
            require(p.get('cwd') == env_cwds[worker['checkout']] and (root / p['cwd']).resolve() == (root / env_cwds[worker['checkout']]).resolve(),
                    'worker pane %s must use exactly the cwd of environment %s' % (p['name'], worker['checkout']))


def validate(cfg, root):
    def require(ok, message):
        if not ok:
            raise ValueError(message)

    peers = cfg.get('schema_version') == 6 and 'peers' in cfg
    removed = removed_features(cfg)
    require(not removed, '; '.join(removed))

    def shape(value, allowed, required, label):
        require(isinstance(value, dict), label + ' must be an object')
        require(set(value) <= set(allowed) and set(required) <= set(value), label + ' has unknown or missing fields')

    envs = cfg.get('environments', [])
    require(isinstance(envs, list), 'environments must be an array')
    require('environments' not in cfg or bool(envs), 'environments must not be empty')
    sessions = {s['id']: s for s in cfg['sessions']}
    panes = {p['name']: p for s in sessions.values() for p in s['panes']}
    roles = cfg.get('harness', {}).get('roles', {})
    active = cfg.get('harness', {}).get('enabled', False)
    if peers:
        require(isinstance(cfg['peers'], dict) and isinstance(cfg['peers'].get('session'), str), 'peers must be an object with a session')
        for e in envs:
            require(isinstance(e, dict), 'environment must be an object')
            for key in ('orchestrator', 'shared_sessions'):
                require(key not in e, 'environments[].%s is not allowed with peers: orchestrators are peers, not per-environment' % key)
            require(e.get('development', []) == [], 'environments[].development must be empty or absent with peers: workers are started on demand')
            require(e.get('executors', 'one') in ('one', 'many'), 'environments[].executors must be "one" or "many"')
    declared = [e.get('orchestrator') for e in envs if isinstance(e, dict) and 'orchestrator' in e]
    require(all(isinstance(name, str) for name in declared) and len(declared) == len(set(declared)), 'environment orchestrator requires a unique pane')
    seen_ids, seen_sessions, seen_roots, coordinators, control_roots = set(), set(), [], set(), []
    for e in envs:
        if peers:
            shape(e, ['id', 'cwd', 'development', 'services', 'branch', 'executors'], ['id', 'cwd', 'services'], 'environment')
        else:
            shape(e, ['id', 'cwd', 'development', 'services', 'orchestrator', 'shared_sessions', 'branch'], ['id', 'cwd', 'development', 'services'], 'environment')
        require(isinstance(e['id'], str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', e['id']), 'invalid environment id')
        require(e['id'] != 'root' and e['id'] not in seen_ids, 'reserved or duplicate environment id')
        seen_ids.add(e['id'])
        require(isinstance(e['cwd'], str) and e['cwd'] and not Path(e['cwd']).is_absolute(), 'environment cwd must be relative')
        cwd = (root / e['cwd']).resolve(strict=True)
        require(cwd.is_dir() and cwd != root and inside(cwd, root), 'environment cwd must be a distinct contained directory')
        require(not any(inside(cwd, r) or inside(r, cwd) for r in seen_roots), 'environment roots overlap')
        seen_roots.append(cwd)
        selected = []
        for kind in ['development', 'services']:
            ids = e.get(kind, []) if peers else e[kind]
            require(isinstance(ids, list) and all(isinstance(i, str) for i in ids), kind + ' must contain session ids')
            require(kind != 'development' or peers or bool(ids), 'development must not be empty')
            for sid in ids:
                require(sid in sessions and sid not in seen_sessions, 'unknown or multiply owned environment session')
                seen_sessions.add(sid)
                for p in sessions[sid]['panes']:
                    selected.append(p)
                    shell = pane_runtime(cfg, p) == 'shell'
                    require(kind != 'services' or shell, 'services sessions must contain only shell panes')
                    if p['name'] != e.get('orchestrator'):
                        pcwd = (root / p.get('cwd', '.')).resolve(strict=True)
                        if p['role'] == 'service' and 'command' not in p:
                            require(inside(pcwd, root), 'service shell cwd escapes workspace root')
                        else:
                            require(inside(pcwd, cwd), 'environment pane cwd escapes its repository')
        if 'orchestrator' in e:
            name = e['orchestrator']
            require(active and isinstance(name, str) and name in panes and name not in coordinators, 'environment orchestrator requires enabled harness and unique pane')
            require(any(p['name'] == name for sid in e['development'] for p in sessions[sid]['panes']) and panes[name]['role'] == roles.get('orchestrator'), 'environment orchestrator must be its development coordinator')
            require(not panes[name].get('optional', False), 'environment orchestrator cannot be optional')
            control = (root / panes[name].get('cwd', '.')).resolve(strict=True)
            require(control.is_dir() and inside(control, root), 'environment orchestrator requires workspace root or a contained control directory')
            if control != root:
                control_roots.append(control)
            coordinators.add(name)
        if active and not peers:
            workers = [p for p in selected if p['role'] in [roles['executor'], roles['reviewer']]]
            require(len([p for p in workers if p['role'] == roles['executor']]) == 1 and len([p for p in workers if p['role'] == roles['reviewer']]) == 1, 'each environment requires one executor/reviewer pair')
            require(all((root / p['cwd']).resolve() == cwd and p['cwd'] == e['cwd'] for p in workers), 'environment workers must bind exactly to repository root')
    for e in envs:
        # A shared services session is started by several environments and
        # stopped only by the root coordinator, the user or its idle watcher.
        shared = e.get('shared_sessions', [])
        require(isinstance(shared, list) and all(isinstance(i, str) for i in shared) and len(shared) == len(set(shared)), 'shared_sessions must contain unique session ids')
        require(not shared or 'orchestrator' in e, 'shared_sessions requires an environment orchestrator')
        for sid in shared:
            require(sid in sessions and sid not in seen_sessions, 'shared_sessions must name a configured session that no environment owns')
            require(all(pane_runtime(cfg, p) == 'shell' and p['role'] not in roles.values() for p in sessions[sid]['panes']), 'shared sessions must contain only service shell panes')
    # Environments on one repository (linked worktrees, or a worktree and its
    # main checkout) share every ref. Each such lane declares the one branch
    # its executor may write (git.lane_ref).
    commons = {e['id']: git_common_dir((root / e['cwd']).resolve()) for e in envs}
    shared_repos = [c for c, _ in commons.values() if c is not None]
    declared_branches = [e['branch'] for e in envs if 'branch' in e]
    require(all(branch_name_valid(b) for b in declared_branches), 'environment branch must be a safe literal branch name')
    require(len(declared_branches) == len(set(declared_branches)), 'environment branches must be unique')
    targets = cfg.get('orchestration', {}).get('targets', []) if isinstance(cfg.get('orchestration'), dict) else []
    for e in envs:
        common, linked = commons[e['id']]
        if common is not None and (linked or shared_repos.count(common) > 1):
            require('branch' in e, 'environments that share a git repository must each declare branch')
        for t in targets if 'branch' in e else []:
            if isinstance(t, dict) and t.get('cwd') == e['cwd']:
                require(t.get('work_branch') == e['branch'], 'an orchestration target in an environment with branch must use it as work_branch')
    if envs:
        require(cfg.get('behavior', {}).get('stop_scope', 'selected') == 'selected', 'environments require stop_scope selected')
        require(not any(inside(c, r) or inside(r, c) for c in control_roots for r in seen_roots), 'coordinator directories must not overlap repositories')
        require(not any(inside(a, b) or inside(b, a) for i, a in enumerate(control_roots) for b in control_roots[i+1:]), 'coordinator directories overlap')
        if peers:
            validate_peers(cfg, root, envs, sessions, roles, require)
        elif active:
            roots = [p for p in panes.values() if p['role'] == roles['orchestrator'] and p['name'] not in coordinators]
            require(len(roots) <= 1 and all((root / p.get('cwd', '.')).resolve() == root for p in roots), 'zero or one unbound root orchestrator at workspace root is required')
            require(bool(roots) or all('orchestrator' in e for e in envs), 'workers require an environment orchestrator when no unbound root exists')
            for s in sessions.values():
                if s['id'] not in seen_sessions:
                    require(all(p['role'] not in [roles['executor'], roles['reviewer']] for p in s['panes']), 'all workers must belong to an environment')
    browsers = cfg.get('browsers', [])
    require(isinstance(browsers, list), 'browsers must be an array')
    require(not ('browser' in cfg and 'browsers' in cfg), 'use browser or browsers, never both')
    require('browsers' not in cfg or bool(browsers), 'browsers must not be empty')
    browser_sessions, ports, servers = set(), set(), set()
    for b in browsers:
        shape(b, ['session_id', 'pane_name', 'port', 'chrome_program', 'mcp_package', 'mcp_server_name'], ['session_id', 'port', 'chrome_program', 'mcp_package'], 'browser')
        sid = b['session_id']
        require(isinstance(sid, str) and sid in sessions and sid not in browser_sessions, 'browser must bind a unique session')
        browser_sessions.add(sid)
        ps = sessions[sid]['panes']
        name = b.get('pane_name', ps[0]['name'] if len(ps) == 1 else None)
        selected = [p for p in ps if p['name'] == name]
        require(len(selected) == 1, 'browser must select exactly one pane')
        p = selected[0]
        require(pane_runtime(cfg, p) == 'shell' and p['role'] == 'service' and not p.get('optional') and 'command' not in p and 'port' not in p, 'browser pane must be a nonoptional service shell without command/port')
        require(type(b['port']) is int and 1 <= b['port'] <= 65535 and b['port'] not in ports, 'browser port invalid or duplicated')
        ports.add(b['port'])
        require(isinstance(b['chrome_program'], str) and bool(b['chrome_program']), 'browser program required')
        require(isinstance(b['mcp_package'], str) and re.fullmatch(r'chrome-devtools-mcp@[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.]+)?', b['mcp_package']), 'browser MCP package must be pinned')
        server = b.get('mcp_server_name', 'chrome-devtools')
        require(isinstance(server, str) and re.fullmatch(r'[A-Za-z0-9_-]+', server) and server not in servers, 'browser MCP names must be safe and unique')
        servers.add(server)
    all_ports = [p['port'] for p in panes.values() if 'port' in p] + list(ports) + ([cfg['browser']['port']] if 'browser' in cfg else [])
    require(len(all_ports) == len(set(all_ports)), 'v5 service and browser ports must be unique')
    if envs and cfg.get('orchestration', {}).get('enabled'):
        require(all(any(e['cwd'] == t['cwd'] for e in envs) for t in cfg['orchestration']['targets']), 'orchestration targets must exactly bind an environment cwd')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3 or sys.argv[1] != 'validate':
            raise ValueError('usage: workspace-v5.py validate ROOT (JSON on stdin)')
        validate(json.load(sys.stdin), Path(sys.argv[2]).resolve(strict=True))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
