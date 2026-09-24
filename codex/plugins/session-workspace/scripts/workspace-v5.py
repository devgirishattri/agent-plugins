#!/usr/bin/env python3
"""Closed v5 environment validation; no network or credential reads."""
import json
import re
import sys
from pathlib import Path


def inside(path, root):
    return path == root or root in path.parents


def pane_runtime(cfg, pane):
    return pane.get('runtime', cfg['roles'][pane['role']]['runtime'])


def validate(cfg, root):
    def require(ok, message):
        if not ok:
            raise ValueError(message)

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
    declared = [e.get('orchestrator') for e in envs if isinstance(e, dict) and 'orchestrator' in e]
    require(all(isinstance(name, str) for name in declared) and len(declared) == len(set(declared)), 'environment orchestrator requires a unique pane')
    seen_ids, seen_sessions, seen_roots, coordinators, control_roots = set(), set(), [], set(), []
    for e in envs:
        shape(e, ['id', 'cwd', 'development', 'services', 'orchestrator', 'jev'], ['id', 'cwd', 'development', 'services'], 'environment')
        require(isinstance(e['id'], str) and re.fullmatch(r'[a-z0-9][a-z0-9-]*', e['id']), 'invalid environment id')
        require(e['id'] != 'root' and e['id'] not in seen_ids, 'reserved or duplicate environment id')
        seen_ids.add(e['id'])
        require(isinstance(e['cwd'], str) and e['cwd'] and not Path(e['cwd']).is_absolute(), 'environment cwd must be relative')
        cwd = (root / e['cwd']).resolve(strict=True)
        require(cwd.is_dir() and cwd != root and inside(cwd, root), 'environment cwd must be a distinct contained directory')
        require(not any(inside(cwd, r) or inside(r, cwd) for r in seen_roots), 'environment roots overlap')
        seen_roots.append(cwd)
        require('jev' not in e or type(e['jev']) is bool, 'environment jev must be boolean')
        selected = []
        for kind in ['development', 'services']:
            ids = e[kind]
            require(isinstance(ids, list) and all(isinstance(i, str) for i in ids), kind + ' must contain session ids')
            require(kind != 'development' or bool(ids), 'development must not be empty')
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
        if active:
            workers = [p for p in selected if p['role'] in [roles['executor'], roles['reviewer']]]
            require(len([p for p in workers if p['role'] == roles['executor']]) == 1 and len([p for p in workers if p['role'] == roles['reviewer']]) == 1, 'each environment requires one executor/reviewer pair')
            require(all((root / p['cwd']).resolve() == cwd and p['cwd'] == e['cwd'] for p in workers), 'environment workers must bind exactly to repository root')
    if envs:
        require(cfg.get('behavior', {}).get('stop_scope', 'selected') == 'selected', 'environments require stop_scope selected')
        require(not any(inside(c, r) or inside(r, c) for c in control_roots for r in seen_roots), 'coordinator directories must not overlap repositories')
        require(not any(inside(a, b) or inside(b, a) for i, a in enumerate(control_roots) for b in control_roots[i+1:]), 'coordinator directories overlap')
        if active:
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
    integrations = cfg.get('integrations', {})
    shape(integrations, ['jev'], [], 'integrations')
    if 'jev' in integrations:
        j = integrations['jev']
        shape(j, ['enabled', 'mode', 'credential_file', 'model'], ['enabled'], 'integrations.jev')
        require(type(j['enabled']) is bool, 'jev.enabled must be boolean')
        require(j.get('mode', 'shadow') in ['shadow', 'advisory'], 'invalid Jev mode')
        require(j.get('model', 'jev-1.13.0') == 'jev-1.13.0', 'Jev model must be pinned to the evaluated version')
        if 'credential_file' in j:
            f = j['credential_file']
            require(isinstance(f, str) and bool(f) and not Path(f).is_absolute() and '..' not in Path(f).parts, 'credential_file must be a relative contained reference')
        # No path probing: off must not inspect credentials. Enabled availability
        # is checked by the optional adapter, never by workspace startup.


if __name__ == '__main__':
    try:
        if len(sys.argv) != 3 or sys.argv[1] != 'validate':
            raise ValueError('usage: workspace-v5.py validate ROOT (JSON on stdin)')
        validate(json.load(sys.stdin), Path(sys.argv[2]).resolve(strict=True))
    except (ValueError, KeyError, TypeError, OSError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(1)
