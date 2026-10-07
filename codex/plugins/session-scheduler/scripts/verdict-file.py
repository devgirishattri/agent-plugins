#!/usr/bin/env python3
"""Byte-level helpers for scheduler verdict artifacts (run as python3 -I).

Internal to the scheduler scripts; not an agent-callable command. Every
subcommand works on raw bytes so no shell command substitution ever sees an
unvalidated verdict body (NUL bytes and invalid UTF-8 are refused here).

  prepare  copy an already-checked own draft into an exclusive 0600 artifact
  verify   confirm an artifact is a private regular file with the recorded SHA-256
  show     print an artifact's text only after verify succeeds
  excerpt  print the bounded first line of a verified artifact
  pointer  compose the bounded inline-fallback pointer line

Exit 0 on success; non-zero with a reason on stderr and nothing on stdout.
"""
import argparse
import hashlib
import json
import os
import re
import stat
import sys

HEX64 = re.compile(r"[0-9a-f]{64}\Z")
IDENT = re.compile(r"[0-9]+:[0-9]+\Z")
EXCERPT_BYTES = 200


def refuse(message):
    print("ERROR: " + message, file=sys.stderr)
    raise SystemExit(1)


def read_fd(fd, limit):
    """Read at most limit+1 bytes so an oversize file is detected, not buffered."""
    chunks, total = [], 0
    while total <= limit:
        chunk = os.read(fd, min(65536, limit + 1 - total))
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks)


def cut_utf8(text, limit):
    """Cut text to at most limit UTF-8 bytes on a character boundary."""
    raw = text.encode("utf-8")
    if len(raw) <= limit:
        return text
    return raw[:limit].decode("utf-8", "ignore")


def one_line(text):
    return "".join(" " if (ch.isspace() or ord(ch) < 32 or ord(ch) == 127) else ch for ch in text).strip()


def excerpt(text, limit=EXCERPT_BYTES):
    """First non-blank line, control characters flattened, at most limit bytes."""
    line = ""
    for candidate in text.splitlines():
        if candidate.strip():
            line = one_line(candidate)
            break
    line = line or "(verdict)"
    if len(line.encode("utf-8")) <= limit:
        return line
    return cut_utf8(line, limit - 3).rstrip() + "..."


def prepare(args):
    if not IDENT.fullmatch(args.ident) or not HEX64.fullmatch(args.sha) or args.size < 0 or args.max_bytes < 1:
        refuse("invalid draft check result")
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(args.src, flags)
    except OSError as exc:
        refuse("cannot open the note file: %s" % exc.strerror)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            refuse("note file is not a single-link regular file")
        if "%d:%d" % (info.st_dev, info.st_ino) != args.ident:
            refuse("note file is not the file that was checked (replaced since the check)")
        if info.st_size > args.max_bytes:
            refuse("note file is %d bytes; the limit is %d (SESSION_SCHEDULER_NOTE_MAX_BYTES)" % (info.st_size, args.max_bytes))
        data = read_fd(fd, args.max_bytes)
    finally:
        os.close(fd)
    if len(data) > args.max_bytes:
        refuse("note file exceeds %d bytes (SESSION_SCHEDULER_NOTE_MAX_BYTES)" % args.max_bytes)
    if len(data) != args.size or hashlib.sha256(data).hexdigest() != args.sha:
        refuse("note file changed after it was checked")
    if b"\x00" in data:
        refuse("note file contains a NUL byte")
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError:
        refuse("note file is not valid UTF-8")
    if not text.strip():
        refuse("note file is empty")
    # Exclusive artifact: O_EXCL never replaces, O_NOFOLLOW never follows.
    try:
        out = os.open(args.dest, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
    except OSError as exc:
        refuse("cannot create the verdict artifact: %s" % exc.strerror)
    created = True
    try:
        try:
            view = memoryview(data)
            while view:
                written = os.write(out, view)
                view = view[written:]
            os.fchmod(out, 0o600)
            os.fsync(out)
        finally:
            os.close(out)
        check = verify_path(args.dest, args.sha)
        if check:
            refuse("verdict artifact failed verification: " + check)
        created = False
    except OSError as exc:
        refuse("cannot write the verdict artifact: %s" % exc.strerror)
    finally:
        if created:
            try:
                os.unlink(args.dest)
            except OSError:
                pass
    summary = excerpt(args.summary if args.summary else text)
    note = "%s (verdict %s sha256:%s)" % (summary, args.dest, args.sha)
    print(json.dumps({"sha256": args.sha, "size": len(data), "line": summary, "note": note}, ensure_ascii=False))
    return 0


def verify_path(path, sha):
    """Return an empty string when path is a private regular file with this SHA-256."""
    if not HEX64.fullmatch(sha):
        return "invalid digest"
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0))
    except OSError as exc:
        return "cannot open: %s" % exc.strerror
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_uid != os.getuid():
            return "not a single-link regular file owned by this user"
        if info.st_mode & 0o077:
            return "artifact is not private (0600)"
        data = read_fd(fd, 64 * 1024 * 1024)
    finally:
        os.close(fd)
    if hashlib.sha256(data).hexdigest() != sha:
        return "SHA-256 does not match"
    return ""


def verify(args):
    problem = verify_path(args.path, args.sha)
    if problem:
        refuse(problem)
    return 0


def show(args):
    problem = verify_path(args.path, args.sha)
    if problem:
        refuse(problem)
    with open(args.path, "rb") as handle:
        data = handle.read()
    if hashlib.sha256(data).hexdigest() != args.sha:
        refuse("SHA-256 does not match")
    sys.stdout.buffer.write(data)
    return 0


def excerpt_cmd(args):
    problem = verify_path(args.path, args.sha)
    if problem:
        refuse(problem)
    with open(args.path, "rb") as handle:
        data = handle.read()
    if hashlib.sha256(data).hexdigest() != args.sha:
        refuse("SHA-256 does not match")
    print(excerpt(data.decode("utf-8", "replace")))
    return 0


def pointer(args):
    suffix = " \u2014 full verdict recorded: task-status %s" % args.task
    head = "[task:%s] [event:%s]" % (args.task, args.event)
    minimal = len((head + suffix).encode("utf-8"))
    if args.max_bytes < minimal:
        refuse("send limit %d is below the %d bytes a verdict pointer needs" % (args.max_bytes, minimal))
    budget = args.max_bytes - minimal - 1  # bytes left for " " + the first line
    line = one_line(args.line) or "(verdict)"
    if len(line.encode("utf-8")) > budget:
        # The ellipsis must fit the remaining budget too; with no room at all the
        # first line is omitted and only the event and recovery pointer remain.
        line = cut_utf8(line, budget - 3).rstrip() + "..." if budget >= 3 else ""
    print(head + (" " + line if line else "") + suffix)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("prepare")
    p.add_argument("--src", required=True)
    p.add_argument("--ident", required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--size", required=True, type=int)
    p.add_argument("--max-bytes", required=True, type=int)
    p.add_argument("--dest", required=True)
    p.add_argument("--summary", default="")
    p.set_defaults(run=prepare)
    for name, run in (("verify", verify), ("show", show), ("excerpt", excerpt_cmd)):
        p = sub.add_parser(name)
        p.add_argument("--path", required=True)
        p.add_argument("--sha", required=True)
        p.set_defaults(run=run)
    p = sub.add_parser("pointer")
    p.add_argument("--task", required=True)
    p.add_argument("--event", required=True)
    p.add_argument("--line", required=True)
    p.add_argument("--max-bytes", required=True, type=int)
    p.set_defaults(run=pointer)
    args = parser.parse_args()
    return args.run(args)


if __name__ == "__main__":
    raise SystemExit(main())
