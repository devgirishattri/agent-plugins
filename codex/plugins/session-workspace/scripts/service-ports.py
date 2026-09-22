#!/usr/bin/env python3
"""Bounded loopback port observations, never interpreted as process ownership."""
import json
import socket
import subprocess
import sys


def listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=.25):
            return True
    except OSError:
        return False


def preflight(plan, target):
    for session in plan['sessions']:
        if target not in ('all', session['id']):
            continue
        for pane in session['panes']:
            if pane['browser'] or not pane['port'] or not pane['command'] or pane['skip_unresolved']:
                continue
            if not listening(pane['port']):
                continue
            # A managed live pane is kept by the idempotent lifecycle. This is
            # only a conflict preflight, not proof it owns the listening socket.
            proc = subprocess.run(['tmux', 'list-panes', '-t', '=' + session['name'], '-F', '#{@session_workspace_project}\t#{@session_workspace_pane}\t#{pane_dead}\t#{@session_workspace_launched}'], capture_output=True, text=True)
            expected = [plan['project']['id'], pane['name'], '0', pane['runtime']['name']]
            if not any(line.split('\t') == expected for line in proc.stdout.splitlines()):
                print('ERROR: service port occupied before launch: ' + str(pane['port']) + ' (' + pane['name'] + ')', file=sys.stderr)
                return 1
    return 0


if __name__ == '__main__':
    if sys.argv[1] == 'probe':
        print('listening' if listening(int(sys.argv[2])) else 'not-listening')
    else:
        sys.exit(preflight(json.load(sys.stdin), sys.argv[1]))
