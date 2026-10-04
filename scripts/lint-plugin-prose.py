#!/usr/bin/env python3
"""Read-only, advisory Markdown prose checks; not an ASD-STE100 validator."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
WORDS = re.compile(r"[A-Za-z]+(?:['’-][A-Za-z]+)*")
PREFER = {
    "utilize": "use", "utilise": "use", "utilization": "use",
    "commence": "start", "aforementioned": "name the item",
    "herein": "name the location", "henceforth": "from now on",
}


def eligible(path):
    """Only authoring surfaces, never eval prompts, generated reports or stores."""
    parts = Path(path).parts
    return path in {"README.md", "shared/PLUGIN_WRITING.md", "shared/PROSE_EVALUATION.md"} or (
        path.endswith('.md') and
        (parts[:1] == ('plugins',) or parts[:2] == ('codex', 'plugins')) and
        any(p in {'skills', 'commands', 'agents', 'assets'} for p in parts) and
        'evals' not in parts
    )


def tracked_paths(root, revision=None):
    if revision is None:
        args = ['git', 'ls-files', '-z']
    else:
        commit = subprocess.check_output(
            ['git', 'rev-parse', '--verify', '--end-of-options', revision + '^{commit}'],
            cwd=root, stderr=subprocess.PIPE, text=True).strip()
        args = ['git', 'diff', '--name-only', '--diff-filter=ACMRT', '-z', commit, '--']
    result = subprocess.check_output(args, cwd=root, stderr=subprocess.PIPE)
    return [root / p for p in result.decode('utf-8').split('\0')
            if p and eligible(p) and (root / p).exists()]


def prose_blocks(text):
    """Yield (line, procedural, prose) with fenced/literal material excluded."""
    lines = text.splitlines()
    # GFM tables may omit their outside pipes. Mask header/delimiter/body rows.
    table_rows = set()
    for i, line in enumerate(lines):
        cells = line.strip().strip('|').split('|')
        if (i and len(cells) > 1
                and len(lines[i - 1].strip().strip('|').split('|')) == len(cells)
                and all(re.fullmatch(r'\s*:?-+:?\s*', c) for c in cells)):
            table_rows.update({i - 1, i})
            j = i + 1
            while j < len(lines) and '|' in lines[j] and lines[j].strip():
                table_rows.add(j)
                j += 1
    frontmatter_end = 0
    if lines and lines[0].strip() == '---':
        for i in range(1, min(len(lines), 101)):
            if lines[i].strip() in {'---', '...'}:
                if any(re.match(r'^[\w-]+:', part) for part in lines[1:i]):
                    frontmatter_end = i + 1
                break
    fence = None
    comment = False
    block = []
    start = 0
    procedural = False
    list_indent = None
    indented_code = False

    def fence_marker(line):
        match = re.match(r'^(\s*)(`{3,}|~{3,})', line)
        if not match:
            return None
        indent = len(match[1].expandtabs(4))
        if indent <= 3 or (list_indent is not None and list_indent <= indent <= list_indent + 3):
            return match
        return None

    def flush():
        nonlocal block
        if block:
            item = (start, procedural, ' '.join(block))
            block = []
            return item
        return None

    for number, original in enumerate(lines, 1):
        if number <= frontmatter_end:
            continue
        line = original
        if fence:
            closing = fence_marker(line)
            if (closing and closing[2][0] == fence[0] and len(closing[2]) >= len(fence)
                    and not line[closing.end():].strip()):
                fence = None
            continue
        # Inline code may contain literal HTML comment delimiters. Remove
        # balanced same-line spans before interpreting those delimiters.
        if not fence_marker(line):
            line = re.sub(r'(`+).*?\1', '', line)
        if comment:
            if '-->' not in line:
                continue
            line = line.split('-->', 1)[1]
            comment = False
        while '<!--' in line:
            before, tail = line.split('<!--', 1)
            if '-->' in tail:
                line = before + tail.split('-->', 1)[1]
            else:
                line = before
                comment = True
                break
        match = fence_marker(line)
        if match:
            item = flush()
            if item:
                yield item
            fence = match[2]
            continue
        indent = len(line.expandtabs(4)) - len(line.expandtabs(4).lstrip())
        marker = re.match(r'^\s*(?:[-+*]|\d+[.)])\s+', line)
        if marker and indent >= 4 and list_indent is None:
            marker = None
        if line.strip() and indent == 0 and not marker:
            list_indent = None
        previous_blank = number == 1 or not lines[number - 2].strip()
        indented_code = bool(indent >= 4 and not marker and (
            indent >= list_indent + 4 if list_indent is not None
            else previous_blank or indented_code))
        if (number - 1 in table_rows or not line.strip() or re.match(r'^\s*(?:#{1,6}\s|>|\|)', line)
                or re.match(r'^\s*\[[^]]+\]:', line)
                or indented_code):
            item = flush()
            if item:
                yield item
            continue
        if marker:
            item = flush()
            if item:
                yield item
            list_indent = len(line[:marker.end()].expandtabs(4))
            line = line[marker.end():]
        if not block:
            start, procedural = number, bool(marker)
        line = re.sub(r'!?\[([^]]*)\]\([^)]*\)', r'\1', line)
        line = re.sub(r'https?://\S+', '', line)
        line = re.sub(r'<[^>]*>', '', line)
        block.append(line)
    item = flush()
    if item:
        yield item


def lint(text, path):
    findings = []
    for line, procedural, prose in prose_blocks(text):
        limit = 20 if procedural else 25
        for sentence in re.split(r'[.!?](?:\s+|$)', prose):
            words = WORDS.findall(sentence)
            if len(words) > limit:
                findings.append(dict(path=path, line=line, rule='sentence-length',
                    message=f'{len(words)} words; review the {limit}-word target',
                    excerpt=sentence.strip()[:160]))
        for term, preferred in PREFER.items():
            if re.search(r'\b' + re.escape(term) + r'\b', prose, re.I):
                findings.append(dict(path=path, line=line, rule='word-choice',
                    message=f'Consider {preferred!r} instead of {term!r}; preserve technical meaning',
                    excerpt=prose.strip()[:160]))
    return findings


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('paths', nargs='*', type=Path)
    parser.add_argument('--changed-from', metavar='COMMIT', help='scan current tracked prose changed since this commit')
    parser.add_argument('--json', action='store_true', help='print a machine-readable advisory report')
    args = parser.parse_args(argv)
    if args.paths and args.changed_from:
        parser.error('choose explicit files or --changed-from')
    try:
        paths = args.paths or tracked_paths(ROOT, args.changed_from)
        findings = []
        for path in paths:
            if path.suffix != '.md' or path.is_symlink() or not path.is_file():
                raise ValueError(f'expected a regular, non-symlink Markdown file: {path}')
            findings.extend(lint(path.read_text(encoding='utf-8'), str(path)))
    except (OSError, UnicodeError, ValueError, subprocess.CalledProcessError) as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 2
    report = dict(advisory_only=True, files=len(paths), findings=findings)
    if args.json:
        print(json.dumps(report, indent=2))
    else:
        for item in findings:
            print(f"{item['path']}:{item['line']}: ADVISORY {item['rule']}: {item['message']}")
        print(f'{len(paths)} files; {len(findings)} advisories; no files changed; not an STE compliance check')
    return 0


if __name__ == '__main__':
    sys.exit(main())
