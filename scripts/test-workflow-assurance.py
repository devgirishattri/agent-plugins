#!/usr/bin/env python3
"""Exercise scanner controls, then gate every repository workflow with the same flags."""
import argparse
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[1]
VALID = '''name: control
on: pull_request
permissions:
  contents: read
jobs:
  control:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0
        with:
          persist-credentials: false
      - name: Print title as data
        env:
          TITLE: ${{ github.event.pull_request.title }}
        run: printf '%s\\n' "$TITLE"
'''


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def installer_controls():
    spec = importlib.util.spec_from_file_location('installer', ROOT / 'scripts/install-workflow-tools.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w:gz') as archive:
        member = tarfile.TarInfo('nested/control')
        member.size = 7
        archive.addfile(member, io.BytesIO(b'control'))
    data = stream.getvalue()
    digest = hashlib.sha256(data).hexdigest()
    require(module.verified_binary(data, digest, 'control') == b'control', 'installer valid control failed')
    try:
        module.verified_binary(data + b'tampered', digest, 'control')
    except ValueError as error:
        require('SHA-256 mismatch' in str(error), 'wrong installer failure')
    else:
        raise RuntimeError('installer accepted altered bytes')
    print('PASS installer: matching bytes accepted; altered bytes rejected')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool', choices=('actionlint', 'zizmor'), required=True)
    parser.add_argument('--bin-dir', type=Path, required=True)
    args = parser.parse_args()
    executable = (args.bin_dir / args.tool).resolve()
    pins = json.loads((ROOT / 'scripts/workflow-tools.json').read_text())
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(('SESSION_', 'KNOWLEDGE_', 'ZIZMOR_'))
           and k not in ('TMUX', 'TMUX_PANE', 'GH_TOKEN', 'GITHUB_TOKEN')}
    version = subprocess.run([str(executable), '--version'], env=env, text=True,
                             capture_output=True, check=True).stdout.splitlines()[0]
    require(version in (pins[args.tool]['version'], 'zizmor ' + pins[args.tool]['version']),
            f'unexpected tool version: {version}')
    installer_controls()
    if args.tool == 'actionlint':
        require(shutil.which('shellcheck') is not None, 'ShellCheck must be installed')
        flags = ['-oneline', '-color', '-pyflakes=']
        faults = [
            ('expression', VALID.replace('github.event.pull_request.title', 'unknown_context.title'), '[expression]'),
            ('shell', VALID.replace('"$TITLE"', '$TITLE'), 'SC2086'),
        ]
    else:
        flags = ['--offline', '--no-config', '--no-ignores', '--strict-collection',
                 '--persona=regular', '--min-severity=informational', '--min-confidence=low', '--format=json']
        faults = [
            ('injection', VALID.replace('run: printf', 'run: echo "${{ github.event.pull_request.title }}"; printf'), 'template-injection'),
            ('permissions', VALID.replace('permissions:\n  contents: read\n', ''), 'excessive-permissions'),
            ('credentials', VALID.replace('        with:\n          persist-credentials: false\n', ''), 'artipacked'),
        ]

    def run(paths):
        return subprocess.run([str(executable), *flags, *map(str, paths)], cwd=ROOT,
                              env=env, text=True, capture_output=True, timeout=120)

    with tempfile.TemporaryDirectory(prefix='workflow-controls-') as directory:
        path = Path(directory) / 'control.yml'
        path.write_text(VALID)
        result = run([path])
        require(result.returncode == 0, f'valid control failed: {result.stdout}{result.stderr}')
        if args.tool == 'zizmor':
            require(json.loads(result.stdout) == [], 'valid control has findings')
        print(f'PASS {args.tool}: valid control')
        for name, content, rule in faults:
            path.write_text(content)
            result = run([path])
            require(result.returncode != 0, f'{name}: faulty control passed')
            if args.tool == 'zizmor':
                rules = {f['ident'] for f in json.loads(result.stdout)}
                require(rule in rules, f'{name}: missing {rule}; found {rules}')
            else:
                require(rule in result.stdout, f'{name}: missing {rule}: {result.stdout}{result.stderr}')
            print(f'PASS {args.tool}: {name} rejected with {rule}')

    workflows = sorted((ROOT / '.github/workflows').glob('*.yml')) + sorted((ROOT / '.github/workflows').glob('*.yaml'))
    require(bool(workflows), 'no workflows found')
    result = run(workflows)
    require(result.returncode == 0, f'repository workflow scan failed:\n{result.stdout}{result.stderr}')
    if args.tool == 'zizmor':
        require(json.loads(result.stdout) == [], 'repository workflows have findings')
    print(f'PASS {args.tool}: {len(workflows)} repository workflow(s)')


if __name__ == '__main__':
    main()
