#!/usr/bin/env python3
"""Group selection without rewriting configuration or widening stop scope."""
import argparse
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('verb', choices=['plan', 'status', 'start', 'stop', 'restart', 'reconcile'])
    parser.add_argument('--environment', required=True)
    parser.add_argument('--config')
    parser.add_argument('--services', action='store_true')
    parser.add_argument('--development', action='store_true')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--confirmed', action='store_true')
    parser.add_argument('--no-save', action='store_true')
    parser.add_argument('--no-agents', action='store_true')
    parser.add_argument('--no-services', action='store_true')
    parser.add_argument('--no-attach', action='store_true')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.services and args.development:
        parser.error('choose only one session kind')
    allowed = {'json': ['plan', 'status'], 'confirmed': ['stop'], 'no_save': ['stop', 'restart'], 'no_agents': ['start', 'restart', 'reconcile'], 'no_services': ['start', 'restart', 'reconcile'], 'no_attach': ['start', 'restart'], 'apply': ['reconcile']}
    for option, verbs in allowed.items():
        if getattr(args, option) and args.verb not in verbs:
            parser.error('--' + option.replace('_', '-') + ' is not supported for ' + args.verb)
    if args.verb == 'stop' and not args.confirmed:
        parser.error('stop requires --confirmed')
    config = ['--config', args.config] if args.config else []
    result = subprocess.run(['bash', str(HERE / 'workspace-plan.sh'), *config, '--json'], capture_output=True, text=True)
    if result.returncode:
        print(result.stderr, file=sys.stderr)
        return result.returncode
    plan = json.loads(result.stdout)
    found = [e for e in plan.get('environments', []) if e['id'] == args.environment]
    if len(found) != 1:
        parser.error('unknown environment')
    e = found[0]
    kinds = ['services'] if args.services else ['development'] if args.development else ['development', 'services']
    ids = [sid for kind in kinds for sid in e[kind]]
    config = ['--config', plan['config_path']]
    if args.verb == 'plan':
        plan['sessions'] = [s for s in plan['sessions'] if s['id'] in ids]
        print(json.dumps(plan, indent=2) if args.json else '\n'.join(s['id'] + ': ' + s['name'] for s in plan['sessions']))
        return 0
    # Stop services before workers. No automatic rollback on a partial start:
    # existing sessions must never be destroyed to hide another startup failure.
    if args.verb in ['stop', 'restart']:
        ids.reverse()
    outputs = []
    for sid in ids:
        flags = ['--' + k.replace('_', '-') for k in allowed if getattr(args, k)]
        if args.verb in ['start', 'restart'] and '--no-attach' not in flags:
            flags.append('--no-attach')
        result = subprocess.run(['bash', str(HERE / ('workspace-' + args.verb + '.sh')), sid, *config, *flags], capture_output=args.json, text=True)
        if result.returncode:
            if args.json:
                print(result.stderr, file=sys.stderr)
            print('Environment operation failed at session ' + sid + '; earlier operations remain applied.', file=sys.stderr)
            return result.returncode
        if args.json:
            outputs.append(json.loads(result.stdout))
    if args.json:
        print(json.dumps({'environment': e['id'], 'results': outputs}))
    return 0


if __name__ == '__main__':
    sys.exit(main())
