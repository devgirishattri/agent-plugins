#!/usr/bin/env python3
"""Resolve explicit reviewer shell-read paths; no filesystem mutation (Python 3.9)."""
import json
import os
from pathlib import Path
import stat
import sys


def within(path, root):
    return path == root or root in path.parents


def overlaps(a, b):
    return within(a, b) or within(b, a)


def resolve_paths(config, root):
    root = Path(root).resolve(strict=True)
    stores = config.get("stores", {})

    def absolute(raw):
        p = Path(raw)
        return (p if p.is_absolute() else root / p).resolve()

    protected = [absolute(stores.get("base", ".tmp")),
                 absolute(stores.get("memory", {}).get("root", ".agents/memory"))]
    protected.extend(absolute(p) for p in stores.get("overrides", {}).values())
    secret = config.get("secrets", {}).get("env_file")
    if secret:
        protected.append(absolute(secret))
    home = Path.home().resolve()
    protected.extend(Path(p).expanduser().resolve() for p in [
        os.environ.get("CLAUDE_CONFIG_DIR") or os.environ.get("CLAUDE_HOME") or str(home / ".claude"),
        os.environ.get("CODEX_HOME") or str(home / ".codex")])
    harness = config.get("harness", {})
    result = {}
    for session in config["sessions"]:
        for pane in session["panes"]:
            if "read_paths" not in pane:
                continue
            label = "pane %s read_paths" % pane["name"]
            if config["schema_version"] not in (2, 3, 4, 5) or harness.get("enabled") is not True or pane["role"] != harness.get("roles", {}).get("reviewer"):
                raise ValueError(label + " requires an active harness reviewer")
            paths = pane["read_paths"]
            if not isinstance(paths, list) or len(paths) > 16:
                raise ValueError(label + " must be an array of at most 16 literal paths")
            foreign = []
            environments = config.get("environments", [])
            for environment in environments:
                sessions = environment.get("development", []) + environment.get("services", [])
                if session["id"] not in sessions:
                    foreign.append(absolute(environment["cwd"]))
                    foreign.extend(absolute(p.get("cwd", ".")) for s in config["sessions"]
                                   if s["id"] in sessions for p in s["panes"])
            entries = []
            for raw in paths:
                if (not isinstance(raw, str) or not raw or raw != raw.strip()
                        or raw.startswith(("-", "~")) or any(ord(c) < 32 or ord(c) == 127 for c in raw)
                        or any(c in raw for c in "$`*?[]{}") or ".." in Path(raw).parts):
                    raise ValueError(label + " requires literal paths without expansion or parent traversal")
                path = Path(raw)
                candidate = path if path.is_absolute() else root / path
                # Static authority is lexical. Disk availability is per-pane:
                # an external branch switch must not brick other panes or stop.
                resolved = Path(os.path.normpath(str(candidate)))
                if path.is_absolute() and str(resolved) != raw:
                    raise ValueError(label + " absolute path must be canonical: " + raw)
                if not path.is_absolute() and not within(resolved, root):
                    raise ValueError(label + " relative path escapes project root: " + raw)
                if within(home, resolved) or any(overlaps(resolved, p) for p in protected):
                    raise ValueError(label + " overlaps protected stores, secrets or provider homes: " + raw)
                if any(overlaps(resolved, p) for p in foreign):
                    raise ValueError(label + " overlaps another environment: " + raw)
                if any(overlaps(resolved, Path(e["path"])) for e in entries):
                    raise ValueError(label + " contains duplicate or nested grants: " + raw)
                entry = {"path": str(resolved), "kind": "unavailable"}
                try:
                    if any(p.is_symlink() for p in (resolved, *resolved.parents)):
                        raise ValueError("symlink component")
                    mode = resolved.stat().st_mode
                    kind = "file" if stat.S_ISREG(mode) else "directory" if stat.S_ISDIR(mode) else None
                    if kind is None:
                        raise ValueError("not a regular file or directory")
                    entry["kind"] = kind
                except (OSError, ValueError) as exc:
                    entry["error"] = str(exc)
                entries.append(entry)
            result[pane["name"]] = sorted(entries, key=lambda e: e["path"])
    return result


if __name__ == "__main__":
    try:
        print(json.dumps(resolve_paths(json.load(sys.stdin), sys.argv[1]), sort_keys=True, separators=(",", ":")))
    except (OSError, ValueError, TypeError, KeyError, RuntimeError) as exc:
        print("read_paths: " + str(exc), file=sys.stderr)
        sys.exit(1)
