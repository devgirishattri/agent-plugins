#!/usr/bin/env python3
"""Plan conservative outgoing graph expansion from prompt-matched link text."""
import argparse
import os
import re
import stat
import sys

SLUG = re.compile(r"[a-z0-9]+(?:_[a-z0-9]+)*\Z")
LINK = re.compile(r"\[\[([a-z0-9]+(?:_[a-z0-9]+)*)\]\]")
MAX_FILE = 1024 * 1024


def tokens(text):
    return re.findall(r"[a-z0-9]+", text.lower())


def evidence(terms, sentence):
    # Link names cannot justify themselves. Only the surrounding prose counts.
    words = set(tokens(re.sub(r"\[\[.*?\]\]", " ", sentence)))
    found = []
    for term in terms:
        if term in words:
            found.append(term)
        elif len(term) >= 6 and term.isalpha():
            # Conservative surface-form match, not a semantic inference:
            # e.g. promote/promotion share six leading letters.
            matches = sorted(w for w in words if len(w) >= 6 and w.isalpha() and w[:6] == term[:6])
            if matches:
                found.append(term + "~" + matches[0])
    return ",".join(found)


def read_body(root_fd, slug):
    fd = os.open(slug + ".md", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root_fd)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_size > MAX_FILE:
            return ""
        data = stream.read(MAX_FILE + 1)
    if len(data) > MAX_FILE:
        return ""
    text = data.decode("utf-8")
    lines = text.splitlines()
    if not lines or lines[0] != "---" or "---" not in lines[1:]:
        return ""
    return "\n".join(lines[lines.index("---", 1) + 1:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", required=True)
    parser.add_argument("--seed", action="append", default=[])
    parser.add_argument("--direct", action="append", default=[])
    args = parser.parse_args()
    if len(args.seed) > 2 or any(not SLUG.fullmatch(s) for s in args.seed + args.direct):
        return 1
    raw = sys.stdin.buffer.read(65537)
    if len(raw) > 65536:
        return 1
    terms = list(dict.fromkeys(t for t in tokens(raw.decode("utf-8")) if len(t) >= 4))[:64]
    direct = set(args.direct)
    root = os.open(args.store, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(root).st_uid != os.getuid():
            return 1
        for seed in args.seed:
            try:
                body = read_body(root, seed)
            except (OSError, UnicodeError):
                continue
            found = {}
            # Newlines and sentence/semicolon boundaries keep adjacent topics
            # from lending unrelated words to a link. No frontmatter matching.
            for sentence in re.split(r"(?<=[.!?;])\s+|\n", body):
                targets = [s for s in LINK.findall(sentence) if s not in direct]
                if not targets:
                    continue
                matched = evidence(terms, sentence)
                if matched:
                    for target in targets:
                        found.setdefault(target, matched)
            for target in sorted(found)[:64]:
                print(seed + "\t" + target + "\t" + found[target])
    finally:
        os.close(root)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, UnicodeError, ValueError):
        sys.exit(1)
