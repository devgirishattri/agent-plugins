#!/usr/bin/env python3
"""Run existing scheduler smoke coverage in isolation; retain local evidence.

These receipts check local consistency, not authentic execution or approval.
No recorded command is ever executed by the check operation.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent
PROVIDERS = {"codex": "codex/plugins", "claude": "plugins"}
NOTICE = "Local consistency only; not authenticated execution, review approval, or release authorization."


def digest(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("expected regular file: " + str(path))
    return hashlib.sha256(path.read_bytes()).hexdigest()


def inventory(repo, provider):
    base = repo / PROVIDERS[provider]
    files = [repo / "scripts/verify-scheduler-workflow.py"]
    recipe = base / "session-workspace/skills/verification-recipe"
    roots = [base / name for name in ("session-scheduler", "session-chat", "knowledge", "chronos")]
    roots.append(recipe)
    for root in roots:
        if root.is_symlink() or not root.is_dir():
            raise ValueError("missing or unsafe source directory: " + str(root))
        for path in sorted(root.rglob("*")):
            if path.is_symlink():
                raise ValueError("symlink in source inventory: " + str(path))
            if path.is_file() and "__pycache__" not in path.parts:
                files.append(path)
    return {str(p.relative_to(repo)): digest(p) for p in sorted(files)}


def source_identity(repo, provider):
    result = subprocess.run(["git", "rev-parse", "HEAD"], cwd=repo,
                            capture_output=True, text=True, check=True)
    return {"head": result.stdout.strip(), "files": inventory(repo, provider)}


def private_environment(home):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("SESSION_", "KNOWLEDGE_", "TMUX", "CODEX_", "CLAUDE_", "CHRONOS_"))
           and k not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "CDPATH", "PYTHONPATH")
           and not k.startswith("BASH_FUNC_")}
    env.update(HOME=str(home), TMPDIR=str(home), TMUX_TMPDIR=str(home),
               XDG_CONFIG_HOME=str(home / "config"), XDG_DATA_HOME=str(home / "data"),
               CODEX_HOME=str(home / "codex"), PYTHONDONTWRITEBYTECODE="1")
    return env


def stop_group(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(repo, provider, output, timeout):
    # A new directory prevents accidental overwrite of an earlier receipt.
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    command = ["bash", f"{PROVIDERS[provider]}/session-scheduler/scripts/test-session-scheduler.sh"]
    missing = [name for name in ("bash", "git", "tmux", "jq", "rg") if not shutil.which(name)]
    before = source_identity(repo, provider) if not missing else None
    receipt = {"schema_version": 1, "provider": provider, "source": before,
               "command": command, "platform": platform.platform(),
               "started_at": datetime.now(timezone.utc).isoformat(),
               "timeout_seconds": timeout, "exit_code": None, "notice": NOTICE}
    log_path = output / "output.log"
    with log_path.open("x") as log:
        if missing:
            receipt.update(result="blocked", reason="missing dependencies: " + ", ".join(missing))
            log.write(receipt["reason"] + "\n")
        else:
            # Short paths also keep macOS tmux sockets below its path limit.
            with tempfile.TemporaryDirectory(prefix="sv-", dir="/tmp") as directory:
                fixture = Path(directory)
                env = private_environment(fixture)
                process = None
                try:
                    process = subprocess.Popen(command, cwd=repo, env=env,
                                               stdout=log, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                    code = process.wait(timeout=timeout)
                    receipt.update(exit_code=code, result="passed" if code == 0 else "failed",
                                   reason="existing scheduler smoke suite exited " + str(code))
                except subprocess.TimeoutExpired:
                    receipt.update(result="inconclusive", reason="suite timed out")
                finally:
                    if process is not None:
                        stop_group(process)
                    # TMUX is removed and TMUX_TMPDIR is unique to this run.
                    subprocess.run(["tmux", "kill-server"], env=env,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                   timeout=10, check=False)
    if receipt["result"] == "passed":
        summary = (r"session-scheduler smoke tests: ([1-9][0-9]*) passed, 0 failed"
                   if provider == "codex" else r"=== Results: ([1-9][0-9]*) passed, 0 failed ===")
        match = re.search(summary, log_path.read_text())
        if match is None:
            receipt.update(result="inconclusive", reason="suite completion summary missing")
        else:
            receipt["assertions_reported"] = int(match.group(1))
    after = source_identity(repo, provider) if not missing else None
    if before != after:
        receipt.update(result="inconclusive", reason="source changed during verification")
    receipt.update(finished_at=datetime.now(timezone.utc).isoformat(),
                   log_sha256=digest(log_path))
    (output / "manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(receipt["result"] + ": " + receipt["reason"])
    print(str(output / "manifest.json"))
    return 0 if receipt["result"] == "passed" else 1


def check(repo, output):
    manifest = output / "manifest.json"
    digest(manifest)  # Reject symlink or nonregular receipts before reading.
    data = json.loads(manifest.read_text())
    if not isinstance(data, dict) or data.get("schema_version") != 1:
        raise ValueError("unsupported evidence schema")
    provider = data.get("provider")
    if not isinstance(provider, str) or provider not in PROVIDERS:
        raise ValueError("invalid evidence provider")
    if digest(output / "output.log") != data.get("log_sha256"):
        raise ValueError("output.log digest mismatch")
    if data.get("result") != "passed" or data.get("exit_code") != 0:
        print("not passed: " + str(data.get("result")))
        return 1
    if source_identity(repo, provider) != data.get("source"):
        print("stale: source identity differs; run a fresh verification")
        return 1
    print("passed: recorded suite result and local source/artifact hashes match")
    print(NOTICE)
    return 0


def evidence_path(raw):
    path = Path(raw).absolute()
    # /tmp is a system alias on macOS; normalize ancestors but reject an output
    # supplied through a symlink beneath the repository or another real parent.
    for ancestor in [path, *path.parents]:
        if ancestor.is_symlink() and str(ancestor) not in ("/tmp", "/var"):
            raise ValueError("symlink evidence path: " + str(ancestor))
    return path.resolve()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("run", "check"))
    parser.add_argument("--provider", choices=tuple(PROVIDERS), default="codex")
    parser.add_argument("--output", required=True)
    parser.add_argument("--timeout", type=int, default=300)
    args = parser.parse_args()
    if not 1 <= args.timeout <= 600:
        parser.error("timeout must be between 1 and 600 seconds")
    try:
        output = evidence_path(args.output)
        if not output.is_relative_to(ROOT / ".tmp"):
            raise ValueError("evidence must be inside this checkout's ignored .tmp directory")
        return run(ROOT, args.provider, output, args.timeout) if args.operation == "run" else check(ROOT, output)
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print("invalid/unavailable: " + str(error))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
