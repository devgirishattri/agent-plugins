#!/usr/bin/env python3
"""Install reviewed upstream release bytes into an explicit, disposable directory."""
import argparse
import hashlib
import io
import json
from pathlib import Path
import platform
import tarfile
import urllib.request


def verified_binary(data, digest, name):
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError(f'{name}: SHA-256 mismatch')
    # Never extract archive paths, links or permissions into the filesystem.
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as archive:
        matches = [m for m in archive.getmembers()
                   if Path(m.name).name == name and m.isfile()]
        if len(matches) != 1:
            raise ValueError(f'{name}: expected one regular executable')
        return archive.extractfile(matches[0]).read()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--tool', choices=('actionlint', 'zizmor'), required=True)
    parser.add_argument('--dest', type=Path, required=True)
    args = parser.parse_args()
    pins = json.loads(Path(__file__).with_name('workflow-tools.json').read_text())
    key = f'{platform.system()}-{platform.machine()}'
    pin = pins[args.tool]
    if key not in pin['assets']:
        parser.error(f'unsupported platform: {key}')
    asset = pin['assets'][key]
    with urllib.request.urlopen(asset['url'], timeout=60) as response:
        data = response.read()
    binary = verified_binary(data, asset['sha256'], args.tool)
    args.dest.mkdir(parents=True, exist_ok=True)
    target = args.dest / args.tool
    target.write_bytes(binary)
    target.chmod(0o755)
    print(f"Installed {args.tool} {pin['version']} ({key}); SHA-256 verified")


if __name__ == '__main__':
    main()
