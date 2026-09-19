#!/usr/bin/env python3
"""Opt-in native deletion regression: isolated HOME, no daemon or model calls."""
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
        raise RuntimeError("native deletion regression requires codex on PATH")
    with tempfile.TemporaryDirectory(prefix="sm-delete-", dir="/tmp") as temp:
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
                rpc.call("initialize", {"clientInfo": {"name": "deletion-test", "version": "1"},
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
                         "cli_version": "0.155.0", "source": "cli", "model_provider": "openai"}},
                        {"type": "response_item", "payload": {"type": "message", "role": "user",
                         "content": [{"type": "input_text", "text": "Synthetic deletion fixture"}]}},
                        {"type": "event_msg", "payload": {"type": "user_message", "message": "Synthetic deletion fixture",
                         "images": [], "local_images": [], "text_elements": []}}
                    ]
                    path.write_text("".join(json.dumps({"timestamp": "2026-01-01T00:00:00Z", **r}) + "\n" for r in records))
                    paths.append(path)
                    rpc.call("thread/resume", {"threadId": ident, "path": str(path)})
                    rpc.call("thread/name/set", {"threadId": ident, "name": "Synthetic fixture"})
            finally:
                rpc.close()
            assert rpc.process.poll() is not None, "temporary server did not stop"
            socket = codex_home / "app-server-control/app-server-control.sock"
            assert not socket.exists(), "fixture unexpectedly started a daemon"
            # Name/set persists the imported rows before the owned server exits.
            rows = M.native_snapshot()
            assert all(ident in rows for ident in identifiers), rows
            original_files = [p.read_bytes() for p in paths]
            def bulk(flag):
                result = subprocess.run(["bash", str(SCRIPTS / "delete-all-sessions.sh"), flag, str(project)],
                                        env=env, capture_output=True, text=True, timeout=30)
                assert result.returncode == 0, result.stdout + result.stderr
                return result.stdout
            preview = bulk("--plan")
            assert "ELIGIBLE\t" + identifiers[0] in preview, preview
            assert identifiers[1] not in preview, preview
            assert [p.read_bytes() for p in paths] == original_files, "preview changed history"
            output = bulk("--confirmed")
            assert "1 processed | 1 fully deleted | 0 with failures | 0 skipped" in output, output
            remaining = M.native_snapshot()
            assert identifiers[0] not in remaining, remaining
            assert identifiers[1] in remaining, remaining
            assert not paths[0].exists(), "native deletion left the fixture rollout"
            assert paths[1].read_bytes() == original_files[1], "other project was modified"
            assert not socket.exists(), "deletion unexpectedly started a daemon"
            print("PASS: native preview and bulk deletion without a daemon; other project preserved")
        finally:
            os.environ.clear(); os.environ.update(original)


if __name__ == "__main__":
    main()
