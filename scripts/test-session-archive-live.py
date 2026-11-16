#!/usr/bin/env python3
"""Native archive/unarchive regression: isolated HOME, no daemon or model calls.

Run: python3 -B scripts/test-session-archive-live.py (needs codex on PATH).
"""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import uuid

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "codex/plugins/session-manager/scripts"
SPEC = importlib.util.spec_from_file_location("metadata", SCRIPTS / "session-metadata.py")
M = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(M)


def main():
    executable = shutil.which("codex")
    if not executable:
        raise RuntimeError("native archive regression requires codex on PATH")
    with tempfile.TemporaryDirectory(prefix="sm-archive-", dir="/tmp") as temp:
        home = Path(temp)
        codex_home = home / ".codex"
        binary = codex_home / "packages/standalone/current/codex"
        binary.parent.mkdir(parents=True)
        binary.symlink_to(Path(executable).resolve())
        project, other = home / "project", home / "other"
        project.mkdir(); other.mkdir()
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "SYSTEMROOT", "LANG", "TMPDIR")}
        env.update(HOME=str(home), CODEX_HOME=str(codex_home), XDG_CONFIG_HOME=str(home / ".config"),
                   XDG_CACHE_HOME=str(home / ".cache"))
        original = dict(os.environ)
        os.environ.clear(); os.environ.update(env)
        try:
            identifiers, paths = [], []
            rpc = M.StdioRPC(timeout=10)
            try:
                rpc.call("initialize", {"clientInfo": {"name": "archive-test", "version": "1"},
                                        "capabilities": {"experimentalApi": True}})
                rpc.send({"method": "initialized", "params": {}})
                for cwd in (project, other):
                    ident = str(uuid.uuid4())
                    identifiers.append(ident)
                    path = codex_home / "sessions" / f"rollout-2026-01-01T00-00-00-{ident}.jsonl"
                    path.parent.mkdir(exist_ok=True)
                    records = [
                        {"type": "session_meta", "payload": {"id": ident, "cwd": str(cwd),
                         "timestamp": "2026-01-01T00:00:00Z", "originator": "codex_cli_rs",
                         "cli_version": "0.169.0", "source": "cli", "model_provider": "openai"}},
                        {"type": "response_item", "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "Synthetic archive fixture"}]}},
                        {"type": "event_msg", "payload": {"type": "user_message", "message": "Synthetic archive fixture",
                         "images": [], "local_images": [], "text_elements": []}}
                    ]
                    path.write_text("".join(json.dumps({"timestamp": "2026-01-01T00:00:00Z", **r}) + "\n" for r in records))
                    paths.append(path)
                    rpc.call("thread/resume", {"threadId": ident, "path": str(path)})
                    rpc.call("thread/name/set", {"threadId": ident, "name": "Synthetic fixture"})
            finally:
                rpc.close()
            socket = codex_home / "app-server-control/app-server-control.sock"
            target, kept = identifiers
            other_bytes = paths[1].read_bytes()

            def run(script, *args, cwd=project):
                return subprocess.run(["bash", str(SCRIPTS / script), *args], env=env, cwd=cwd,
                                      capture_output=True, text=True, timeout=60)

            def status(result):
                assert result.returncode == 0, result.stdout + result.stderr
                return result.stdout.splitlines()[0]

            assert status(run("prepare-archive.sh", "archive", target)) == "STATUS\tONE"
            assert status(run("prepare-archive.sh", "unarchive", target)) == "STATUS\tNONE"
            result = run("archive-session.sh", "archive", target)
            assert result.returncode == 0, result.stdout + result.stderr
            assert target not in M.native_snapshot(), "archived session is still active"
            assert M.native_snapshot(archived=True)[target]["archived"], "session missing from archived rows"
            assert not paths[0].exists(), "native archive left the rollout in sessions/"
            assert list((codex_home / "archived_sessions").glob(f"*{target}.jsonl")), "no archived rollout"

            # The resolver now offers it only for unarchive, and the native
            # command refuses a second archive.
            assert status(run("prepare-archive.sh", "archive", target)) == "STATUS\tNONE"
            selection = run("prepare-archive.sh", "unarchive")
            assert status(selection) == "STATUS\tSELECT" and target in selection.stdout, selection.stdout
            assert kept not in selection.stdout, selection.stdout
            again = run("archive-session.sh", "archive", target)
            assert again.returncode != 0 and "must name an active session" in again.stderr, again.stdout + again.stderr

            result = run("archive-session.sh", "unarchive", target)
            assert result.returncode == 0, result.stdout + result.stderr
            assert target in M.native_snapshot(), "unarchived session is not active"
            assert list((codex_home / "sessions").rglob(f"*{target}.jsonl")), "no restored rollout"
            assert status(run("prepare-archive.sh", "archive", target)) == "STATUS\tONE"

            assert paths[1].read_bytes() == other_bytes, "other project was modified"
            assert kept in M.native_snapshot(), "other session left the active list"
            assert not socket.exists(), "archive unexpectedly started a daemon"
            print("PASS: native archive and unarchive round trip without a daemon; other session untouched")
        finally:
            os.environ.clear(); os.environ.update(original)


if __name__ == "__main__":
    main()
