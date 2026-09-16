#!/usr/bin/env python3
"""Check local handoff evidence without executing recorded commands or changing stores."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("handoff_data", Path(__file__).with_name("handoff-data.py"))
schema = importlib.util.module_from_spec(spec)
spec.loader.exec_module(schema)


def git(repo, *args):
    # Ignore inherited repository redirects, injected Git configuration, replacement
    # objects and lazy fetching. These commands only inspect the chosen local repo.
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env.update(GIT_OPTIONAL_LOCKS="0", GIT_NO_LAZY_FETCH="1",
               GIT_NO_REPLACE_OBJECTS="1", GIT_TERMINAL_PROMPT="0")
    return subprocess.run(["git", "--no-pager", "--no-optional-locks", "-c",
                           "core.fsmonitor=false", "-C", str(repo), *args],
                          env=env, stdin=subprocess.DEVNULL, capture_output=True,
                          text=True, timeout=10)


def read_handoff(name):
    if not schema.ID.fullmatch(name):
        raise ValueError("snapshot name must be canonical snake_case")
    store = os.environ.get("SESSION_CONTEXT_HOME")
    if not store:
        raise ValueError("SESSION_CONTEXT_HOME is not set; relaunch with the correct inherited environment")
    # Keep directory and file descriptors anchored throughout the read. Reject a
    # symlink store root, leaf symlink, foreign owner, or special file; never chmod.
    root = os.open(store.rstrip("/") or "/", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        if os.fstat(root).st_uid != os.getuid():
            raise ValueError("context store must be owned by the current user")
        fd = os.open(name + ".md", os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
                raise ValueError("handoff must be an owned regular non-symlink file")
            text = stream.read()
    finally:
        os.close(root)
    return schema.parse_saved(text)


def path_check(root, ref, file_only=False):
    """Stat a relative path without following any symlink component."""
    parts = [p for p in ref.split("/") if p and p != "."]
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        info = os.stat(parts[-1], dir_fd=fd, follow_symlinks=False) if parts else os.fstat(fd)
        if stat.S_ISLNK(info.st_mode):
            return "unverified", "symlink is not followed"
        if stat.S_ISREG(info.st_mode):
            return "verified", "regular file exists; contents and completion not verified"
        if stat.S_ISDIR(info.st_mode) and not file_only:
            return "verified", "directory exists; contents and completion not verified"
        return "mismatch", "expected a regular file" if file_only else "expected a regular file or directory"
    except FileNotFoundError:
        return "missing", "path does not exist"
    except OSError:
        return "unverified", "path could not be inspected without following symlinks"
    finally:
        os.close(fd)


def commit_check(root, ref, shallow, head):
    result = git(root, "cat-file", "-t", ref)
    if result.returncode:
        return ("unverified", "object unavailable in shallow repository; history may be incomplete") if shallow else ("missing", "object unavailable locally; no remote lookup attempted")
    if result.stdout.strip() != "commit":
        return "mismatch", "object exists but is not a commit"
    if head is None:
        return "unverified", "commit exists but HEAD is unborn or unavailable"
    result = git(root, "merge-base", "--is-ancestor", ref, "HEAD")
    if result.returncode == 0:
        return "verified", "commit exists and is reachable from current HEAD; completion not verified"
    if result.returncode == 1:
        return ("unverified", "commit exists but shallow history cannot establish HEAD ancestry") if shallow else ("mismatch", "commit exists but is not an ancestor of current HEAD")
    return "unverified", "commit exists but current HEAD ancestry could not be checked"


def verify(data, repo, repository_id, name, shallow, head):
    checks = []

    def add(category, ref, result, item_id=None, evidence_index=None):
        status, detail = result
        row = dict(category=category, ref=ref, status=status, detail=detail)
        if item_id is not None:
            row["item_id"] = item_id
        if evidence_index is not None:
            row["evidence_index"] = evidence_index
        checks.append(row)

    matched = repository_id == data["scope"]["repository"]
    add("repository", repository_id, (
        "verified" if matched else "mismatch",
        "caller-supplied repository ID matches handoff; repository identity is not independently proven"
        if matched else "caller-supplied repository ID differs from handoff; evidence checks skipped"))
    if matched:
        for ref in data["scope"]["paths"]:
            add("scope", ref, path_check(repo, ref))
        for item in data["items"]:
            if not item["evidence"]:
                add("evidence", "", ("unverified", "no evidence recorded"), item["id"])
            for index, entry in enumerate(item["evidence"]):
                kind, ref = entry["kind"], entry["ref"]
                if kind == "file":
                    result = path_check(repo, ref, file_only=True)
                elif kind == "commit":
                    result = commit_check(repo, ref, shallow, head)
                else:
                    result = ("unverified", "recorded text only; not executed, fetched, or independently corroborated")
                add(kind, ref, result, item["id"], index)
    counts = {status: sum(c["status"] == status for c in checks)
              for status in ("verified", "missing", "mismatch", "unverified")}
    return dict(report_version=1, handoff=name, repository=str(repo), head=head, shallow=shallow,
                repository_id=repository_id, scope_repository=data["scope"]["repository"],
                items=[dict(id=i["id"], reported_status=i["status"]) for i in data["items"]],
                checks=checks, summary=counts,
                notice="Point-in-time local checks only. Item completion, evidence contents, timestamps, freshness and external tickets are not verified.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("name")
    parser.add_argument("--repository-id", required=True, help="explicit logical ID binding this repository to the handoff")
    parser.add_argument("--repo", type=Path, default=Path.cwd(), help="local Git working tree (default: current directory)")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        if not schema.ID.fullmatch(args.repository_id):
            raise ValueError("repository ID must be canonical snake_case")
        data = read_handoff(args.name)
        if args.repository_id != data["scope"]["repository"]:
            raise ValueError("repository ID differs from handoff scope.repository; no evidence checked")
        result = git(args.repo, "rev-parse", "--show-toplevel")
        if result.returncode or not result.stdout.strip():
            raise ValueError("--repo must select a local Git working tree")
        root = Path(result.stdout.rstrip("\n")).resolve(strict=True)
        shallow_result = git(root, "rev-parse", "--is-shallow-repository")
        if shallow_result.returncode or shallow_result.stdout.strip() not in ("true", "false"):
            raise ValueError("cannot inspect repository history completeness")
        head_result = git(root, "rev-parse", "--verify", "-q", "HEAD")
        head = head_result.stdout.strip() if head_result.returncode == 0 else None
        report = verify(data, root, args.repository_id, args.name,
                        shallow_result.stdout.strip() == "true", head)
        if args.json:
            print(json.dumps(report, ensure_ascii=True, sort_keys=True))
        else:
            print("# context-verify: recorded claims are fallible")
            print(report["notice"])
            print("Repository: " + json.dumps(report["repository"], ensure_ascii=True))
            print(f"HEAD: {head or '(unborn or unavailable)'}; shallow: {report['shallow']}")
            for row in report["checks"]:
                label = "/".join(filter(None, [row.get("item_id"), row["category"]]))
                print(f"{row['status'].upper()} {label} {json.dumps(row['ref'], ensure_ascii=True)}: {row['detail']}")
            print("Summary: " + ", ".join(f"{n} {s}" for s, n in report["summary"].items()))
        return 0 if all(c["status"] == "verified" for c in report["checks"]) else 1
    except (ValueError, TypeError, OSError, UnicodeError, RecursionError, subprocess.TimeoutExpired) as error:
        print("ERROR: context-verify: " + " ".join(str(error).splitlines()), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
