#!/usr/bin/env python3
"""Bounded, non-blocking schema-v3 workspace Stop diagnostics."""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import List, Optional

HERE = Path(__file__).resolve().parent
REF_RE = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._/-]*\Z")


def run(argv: List[str], timeout: int = 2) -> subprocess.CompletedProcess:
    return subprocess.run(argv, check=False, capture_output=True, text=True, timeout=timeout)


def safe_ref(value: object) -> Optional[str]:
    if not isinstance(value, str) or not REF_RE.fullmatch(value):
        return None
    if ".." in value or value.endswith("/") or value.endswith(".lock"):
        return None
    return value


def local_ref(root: str, name: str) -> Optional[str]:
    literal = "refs/heads/" + name
    try:
        checked = run(["git", "-C", root, "show-ref", "--verify", "--quiet", "--", literal])
        if checked.returncode != 0:
            return None
        resolved = run(["git", "-C", root, "rev-parse", "--verify", literal + "^{commit}"])
    except (OSError, subprocess.TimeoutExpired):
        return None
    value = resolved.stdout.strip()
    return value if resolved.returncode == 0 and re.fullmatch(r"[0-9a-fA-F]{40,64}", value) else None


def main(argv: List[str]) -> int:
    codex = argv == ["--codex-hook-output"]
    if argv and not codex:
        return 0
    try:
        sys.stdin.read()
    except (OSError, UnicodeError):
        pass
    config = os.environ.get("SESSION_WORKSPACE_CONFIG", "").strip()
    guards_text = os.environ.get("SESSION_WORKSPACE_GUARDS_JSON", "").strip()
    pane_name = os.environ.get("SESSION_WORKSPACE_PANE_NAME", "").strip()
    if not config or not guards_text or not pane_name:
        return 0
    try:
        guards_env = json.loads(guards_text)
        planned = run(["bash", str(HERE / "workspace-plan.sh"), "--config", config, "--json"], timeout=8)
        if planned.returncode != 0:
            return 0
        plan = json.loads(planned.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return 0
    harness = plan.get("harness", {})
    guards = harness.get("guards")
    if not harness.get("active") or guards != guards_env or not isinstance(guards, dict):
        return 0
    panes = [p for s in plan.get("sessions", []) for p in s.get("panes", []) if isinstance(p, dict)]
    current = [p for p in panes if p.get("name") == pane_name]
    roles = harness.get("roles", {})
    if len(current) != 1 or current[0].get("role") != roles.get("orchestrator"):
        return 0

    health = guards.get("workspace_health", {})
    if not isinstance(health, dict):
        return 0
    warnings: List[str] = []
    root = str(plan.get("project", {}).get("root", ""))

    if health.get("warn_root_dirty") is True and root and (Path(root) / ".git").exists():
        try:
            dirty = run(["git", "-C", root, "--no-optional-locks", "status", "--short", "--"])
            if dirty.returncode == 0 and dirty.stdout.strip():
                count = len(dirty.stdout.rstrip("\n").splitlines())
                warnings.append("project root has %d uncommitted path(s)" % count)
        except (OSError, subprocess.TimeoutExpired):
            pass

    if health.get("warn_missing_panes") is True:
        expected = sorted(str(p.get("name")) for p in panes if not p.get("optional", False) and p.get("runtime", {}).get("name") != "shell")
        try:
            listed = run(["tmux", "list-panes", "-a", "-F", "#{@name}"])
            if listed.returncode == 0:
                live = {line.strip() for line in listed.stdout.splitlines() if line.strip()}
                missing = [name for name in expected if name not in live]
                if missing:
                    warnings.append("non-optional workspace panes are missing: " + ", ".join(missing))
        except (OSError, subprocess.TimeoutExpired):
            pass

    ahead = health.get("branch_ahead")
    if isinstance(ahead, dict):
        base = safe_ref(ahead.get("base"))
        release = safe_ref(ahead.get("release"))
        child_roots = sorted({str(p.get("cwd")) for p in panes if p.get("role") == roles.get("executor") and p.get("cwd")})
        if base and release:
            for child in child_roots:
                if not (Path(child) / ".git").exists():
                    continue
                base_hash = local_ref(child, base)
                release_hash = local_ref(child, release)
                if not base_hash or not release_hash:
                    continue
                try:
                    counted = run(["git", "-C", child, "rev-list", "--count", base_hash + ".." + release_hash, "--"])
                    value = counted.stdout.strip()
                    if counted.returncode == 0 and value.isdigit() and int(value) > 0:
                        warnings.append("%s: %s is ahead of %s by %s commit(s)" % (Path(child).name, release, base, value))
                except (OSError, subprocess.TimeoutExpired):
                    continue

    if not warnings:
        return 0
    message = "session-workspace health: " + "; ".join(warnings)
    if codex:
        print(message)
    else:
        print(json.dumps({"systemMessage": message}, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
